// I2: contract + lifecycle test suite. Compiled with the library portion of
// the app (HermesUsage.swift, WITHOUT the @main file) — never into the app.
// Drives UsageModel through a synthetic CollectorExecuting and feeds fixture
// JSON, covering: malformed JSON, incompatible schema, missing-vs-zero,
// profile aggregation shape, stale retention, large outputs (via executor
// integration), and the R1/R2/R3/R6/R7 lifecycle semantics.
import Foundation
import SwiftUI

var failures = 0
var passes = 0

func expect(_ cond: Bool, _ label: String) {
    if cond { passes += 1; print("  ✓ \(label)") }
    else { failures += 1; print("  ✗ FAIL: \(label)") }
}

/// Scripted executor: returns queued outcomes in order.
final class ScriptedExecutor: CollectorExecuting {
    var outcomes: [CollectorOutcome]
    init(_ outcomes: [CollectorOutcome]) { self.outcomes = outcomes }
    func run(timeout: TimeInterval, maxOutputBytes: Int, maxErrorBytes: Int) -> CollectorOutcome {
        if outcomes.isEmpty { return CollectorOutcome(kind: .failure("script exhausted"), elapsed: 0) }
        return outcomes.removeFirst()
    }
}

func jsonData(_ s: String) -> Data { Data(s.utf8) }

@MainActor
func drainModel(_ model: UsageModel, timeout: TimeInterval = 5) async -> Bool {
    // Wait until isLoading goes false after a refresh.
    let start = Date()
    while model.isLoading && Date().timeIntervalSince(start) < timeout {
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return !model.isLoading
}

@main
struct I2Tests {
    static func main() async {
        // ---- JSON contract: decode ----
        print("I2: decode — happy path record")
        do {
            let json = """
            {"id":"hermes","name":"Hermes Agent","schemaVersion":1,"hasLocalStats":true,
             "todayPrompts":5,"todaySessions":2,"todayTotalTokens":1234,
             "recentDays":[{"date":"2026-09-13","messageCount":100}],
             "modelUsage":{"m":{"inputTokens":1,"outputTokens":2}},
             "providerUsage":{"nous":{"tokens":9,"estimatedCostUsd":0.5}},
             "details":{"truncated":false,"totals":{"tokens":999,"calls":10}}}
            """
            let rec = try? JSONDecoder().decode(UsageRecord.self, from: jsonData(json))
            expect(rec?.todayTotalTokens == 1234, "todayTotalTokens decoded")
            expect(rec?.details?.totals?.calls == 10, "details.totals.calls decoded")
            expect(rec?.details?.truncated == false, "details.truncated decoded")
        }

        print("I2: decode — missing vs zero stay distinct")
        do {
            // hasLocalStats present=false, totals.calls absent vs 0.
            let a = try! JSONDecoder().decode(UsageRecord.self, from: jsonData(
                "{\"id\":\"hermes\",\"name\":\"Hermes Agent\",\"schemaVersion\":1,\"hasLocalStats\":false}"))
            expect(a.hasLocalStats == false, "explicit false decodes as false")
            let b = try! JSONDecoder().decode(UsageRecord.self, from: jsonData(
                "{\"id\":\"hermes\",\"name\":\"Hermes Agent\",\"schemaVersion\":1,\"hasLocalStats\":true,\"details\":{\"totals\":{\"calls\":0,\"estimatedUsd\":null}}}"))
            expect(b.details?.totals?.calls == 0, "observed zero stays zero")
            expect(b.details?.totals?.estimatedUsd == nil, "null cost stays nil (unobserved)")
        }

        print("I2: decode — malformed JSON fails cleanly")
        do {
            let bad = try? JSONDecoder().decode(UsageRecord.self, from: jsonData("{\"nope\":"))
            expect(bad == nil, "malformed JSON rejected")
        }

        print("I2: decode — incompatible schema (array) fails")
        do {
            let bad = try? JSONDecoder().decode(UsageRecord.self, from: jsonData("[1,2,3]"))
            expect(bad == nil, "array payload rejected")
        }

        print("I2: decode — unknown extra keys tolerated")
        do {
            let ok = try? JSONDecoder().decode(UsageRecord.self, from: jsonData(
                "{\"id\":\"hermes\",\"name\":\"Hermes Agent\",\"schemaVersion\":1,\"hasLocalStats\":true,\"futureField\":{\"x\":1}}"))
            expect(ok?.hasLocalStats == true, "forward-compatible decode")
        }

        // ---- Lifecycle: success path ----
        print("I2/R6: lifecycle — success sets .success")
        do {
            let m = await MainActor.run { () -> UsageModel in
                let ex = ScriptedExecutor([CollectorOutcome(kind: .success(jsonData(
                    "{\"id\":\"hermes\",\"name\":\"Hermes Agent\",\"schemaVersion\":1,\"hasLocalStats\":true,\"todayTotalTokens\":42}")), elapsed: 0.1)])
                return UsageModel(executor: ex, collectorTimeout: 5)
            }
            let done = await drainModel(m)
            expect(done, "loading finished")
            expect(m.loadState == .success, "state .success, got \(m.loadState)")
            expect(m.record?.todayTotalTokens == 42, "record populated")
            expect(m.isStale == false, "not stale on success")
        }

        print("I2/R6: lifecycle — noData when hasLocalStats false")
        do {
            let m = await MainActor.run { () -> UsageModel in
                let ex = ScriptedExecutor([CollectorOutcome(kind: .success(jsonData(
                    "{\"id\":\"hermes\",\"name\":\"Hermes Agent\",\"schemaVersion\":1,\"hasLocalStats\":false}")), elapsed: 0.05)])
                return UsageModel(executor: ex, collectorTimeout: 5)
            }
            _ = await drainModel(m)
            expect(m.loadState == .noData, "state .noData, got \(m.loadState)")
        }

        print("I2/R6: lifecycle — failure with no prior record → .failed, warning on")
        do {
            let m = await MainActor.run { () -> UsageModel in
                let ex = ScriptedExecutor([CollectorOutcome(kind: .failure("Collector exit 1: boom"), elapsed: 0.05)])
                return UsageModel(executor: ex, collectorTimeout: 5)
            }
            _ = await drainModel(m)
            expect(m.loadState == .failed("Collector exit 1: boom"), "state .failed")
            expect(m.menuBarWarning, "menu bar warns on fresh failure")
            expect(m.record == nil, "no record retained")
        }

        print("I2/R6: lifecycle — failure AFTER success retains record, marks stale")
        do {
            let m = await MainActor.run { () -> UsageModel in
                let ex = ScriptedExecutor([
                    CollectorOutcome(kind: .success(jsonData("{\"id\":\"hermes\",\"name\":\"Hermes Agent\",\"schemaVersion\":1,\"hasLocalStats\":true,\"todayTotalTokens\":7}")), elapsed: 0.05),
                    CollectorOutcome(kind: .failure("Collector timed out"), elapsed: 0.05),
                ])
                return UsageModel(executor: ex, collectorTimeout: 5)
            }
            _ = await drainModel(m)
            expect(m.loadState == .success, "first run succeeded")
            await MainActor.run { m.refresh() }
            _ = await drainModel(m)
            expect(m.isStale, "stale flag set after failed refresh")
            expect(m.record?.todayTotalTokens == 7, "previous record retained visibly")
            if case .stale = m.loadState { expect(true, "state .stale") }
            else { expect(false, "state .stale, got \(m.loadState)") }
            expect(m.menuBarWarning, "menu bar warns when stale")
        }

        print("I2/R6: lifecycle — malformed JSON after success → stale, not silent success")
        do {
            let m = await MainActor.run { () -> UsageModel in
                let ex = ScriptedExecutor([
                    CollectorOutcome(kind: .success(jsonData("{\"id\":\"hermes\",\"name\":\"Hermes Agent\",\"schemaVersion\":1,\"hasLocalStats\":true}")), elapsed: 0.05),
                    CollectorOutcome(kind: .success(jsonData("{\"truncated garbage")), elapsed: 0.05),
                ])
                return UsageModel(executor: ex, collectorTimeout: 5)
            }
            _ = await drainModel(m)
            await MainActor.run { m.refresh() }
            _ = await drainModel(m)
            expect(m.isStale, "parse failure marks stale")
            expect(m.errorText == "Could not parse collector output", "parse error surfaced")
        }

        print("I2/R2: lifecycle — truncated detail surfaces via decoded record")
        do {
            let m = await MainActor.run { () -> UsageModel in
                let ex = ScriptedExecutor([CollectorOutcome(kind: .success(jsonData(
                    "{\"id\":\"hermes\",\"name\":\"Hermes Agent\",\"schemaVersion\":1,\"hasLocalStats\":true,\"details\":{\"truncated\":true,\"totals\":{\"unknownCallRows\":3}}}")), elapsed: 0.05)])
                return UsageModel(executor: ex, collectorTimeout: 5)
            }
            _ = await drainModel(m)
            expect(m.record?.details?.truncated == true, "truncated flag decodes")
            expect(m.record?.details?.totals?.unknownCallRows == 3, "unknownCallRows decodes")
        }

        print("I2: lifecycle — subsequent refresh succeeds after failure (no wedged state)")
        do {
            let m = await MainActor.run { () -> UsageModel in
                let ex = ScriptedExecutor([
                    CollectorOutcome(kind: .failure("Collector exit 1"), elapsed: 0.05),
                    CollectorOutcome(kind: .success(jsonData("{\"id\":\"hermes\",\"name\":\"Hermes Agent\",\"schemaVersion\":1,\"hasLocalStats\":true,\"todayTotalTokens\":9}")), elapsed: 0.05),
                ])
                return UsageModel(executor: ex, collectorTimeout: 5)
            }
            _ = await drainModel(m)
            expect(m.isLoading == false, "isLoading cleared after failure")
            await MainActor.run { m.refresh() }
            _ = await drainModel(m)
            expect(m.loadState == .success, "recovery refresh succeeds")
            expect(m.isLoading == false, "isLoading cleared after recovery")
        }

        // ---- Formatting contract (R8 regression + nil-vs-zero) ----
        print("I2/R8: exactTokens formats with grouping")
        expect(exactTokens(3234511) == "3,234,511 tokens", "grouped, got \(exactTokens(3234511))")
        expect(exactTokens(0) == "0 tokens", "zero")

        // ---- Exact-integer formatting boundary (display-honesty regression) ----
        // NumberFormatter's decimal conversion of a DOUBLE-valued NSNumber
        // rounds at >=2^54 (its shortest round-trip decimal for 2^55 is
        // ...970 while the Double is bit-exact). The Int overload must be
        // exact at every boundary; the old Double path rendered
        // 36,028,797,018,963,968 as 36,028,797,018,963,970 — the pinned
        // regression below is the one that failed.
        print("I2/R8: integer-exact boundaries (2^53 cap, 2^54, 4x2^53)")
        expect(tokenCountString(9_007_199_254_740_992) == "9,007,199,254,740,992",
               "2^53 (collector cap) exact, got \(tokenCountString(9_007_199_254_740_992))")
        expect(tokenCountString(18_014_398_509_481_984) == "18,014,398,509,481,984",
               "2^54 exact (old Double path rendered ...980), got \(tokenCountString(18_014_398_509_481_984))")
        expect(tokenCountString(36_028_797_018_963_968) == "36,028,797,018,963,968",
               "4 x 2^53 = 2^55 exact (PINNED: old path rendered 36,028,797,018,963,970), got \(tokenCountString(36_028_797_018_963_968))")
        expect(exactTokens(36_028_797_018_963_968) == "36,028,797,018,963,968 tokens",
               "exactTokens Int overload exact at 2^55")
        expect(tokenCountString(9_007_199_254_740_993) == "9,007,199,254,740,993",
               "odd value above 2^53 (not representable in Double) still exact via Int, got \(tokenCountString(9_007_199_254_740_993))")

        // Negative handling: textual sign approach — drop the sign, group the
        // magnitude, prepend. Never negates n (which would trap on Int.min).
        // No model path produces negatives, but the function is ours and must
        // be correct at every input. Caught by @turing/@codie at 0550703.
        expect(tokenCountString(0) == "0", "zero")
        expect(tokenCountString(-123) == "-123", "negative 3 digits (coincidence case, was -,123 before guard)")
        expect(tokenCountString(-123456) == "-123,456", "negative 6 digits (coincidence case)")
        expect(tokenCountString(-123456789) == "-123,456,789", "negative 9 digits (was -,123,456,789 before guard)")
        expect(tokenCountString(Int.min) == "-9,223,372,036,854,775,808", "Int.min (traps negation form)")
        expect(tokenCountString(Int.max) == "9,223,372,036,854,775,807", "Int.max")
        expect(tokenCountString(9_007_199_254_740_993) == "9,007,199,254,740,993", "2^53+1 (odd value above 2^53)")

        print("I2/R3: compactCost nil vs zero")
        expect(compactCost(nil) == "—", "nil → em dash")
        expect(compactCost(0) == "$0.00", "zero → $0.00")
        expect(compactCost(0.005) == "$0.0050", "sub-cent precision, got \(compactCost(0.005))")

        print("I2: compactTokens bands")
        expect(compactTokens(999) == "999", "hundreds")
        expect(compactTokens(1500) == "1.5k", "1.5k, got \(compactTokens(1500))")
        expect(compactTokens(2500000) == "2.5M", "2.5M")

        // ---- CollectorRunner.classify contract (shared with real executor) ----
        print("I2/R1: classify — timeout message")
        do {
            let o = CollectorRunner.classify(exitStatus: 0, timedOut: true, outputTruncated: false,
                                             data: Data(), stderrText: "", elapsed: 30)
            if case .failure(let m) = o.kind { expect(m.contains("timed out"), "timeout text") }
            else { expect(false, "expected failure") }
        }
        print("I2/R1: classify — nonzero exit includes stderr")
        do {
            let o = CollectorRunner.classify(exitStatus: 3, timedOut: false, outputTruncated: false,
                                             data: Data(), stderrText: "boom\n", elapsed: 1)
            if case .failure(let m) = o.kind { expect(m == "Collector exit 3: boom", "exit+stderr, got \(m)") }
            else { expect(false, "expected failure") }
        }
        print("I2/R1: classify — empty output is failure not empty success")
        do {
            let o = CollectorRunner.classify(exitStatus: 0, timedOut: false, outputTruncated: false,
                                             data: Data(), stderrText: "", elapsed: 1)
            if case .failure = o.kind { expect(true, "empty output fails") }
            else { expect(false, "empty output must not succeed") }
        }
        print("I2/R1: classify — truncated output refused")
        do {
            let o = CollectorRunner.classify(exitStatus: 0, timedOut: false, outputTruncated: true,
                                             data: Data([0x7B]), stderrText: "", elapsed: 1)
            if case .failure(let m) = o.kind { expect(m.contains("exceeded"), "truncation refused") }
            else { expect(false, "expected refusal") }
        }

        // ---- Aggregation shape: ModelUsage.totalTokens sums all buckets ----
        print("I2: ModelUsage.totalTokens aggregates all four buckets")
        do {
            let mu = ModelUsage(inputTokens: 100, outputTokens: 200,
                                cacheReadInputTokens: 300, cacheCreationInputTokens: 400)
            expect(mu.totalTokens == 1000, "sum = 1000, got \(mu.totalTokens)")
        }

        // ---- R3 regression: provider cost key-space mismatch ----
        print("I2/R3: REGRESSION — provider in totals but not in detail providers")
        do {
            // This is the bug: provider exists in providerUsage with legacy cost 0.0,
            // but is NOT in details.providers (key mismatch or absent).
            // Should return nil (unknown), not 0.0 (would display as "$0.00").
            let rec = try! JSONDecoder().decode(UsageRecord.self, from: jsonData(
                "{\"providerUsage\":{\"openrouter\":{\"tokens\":1000,\"estimatedCostUsd\":0.0}}," +
                "\"details\":{\"providers\":{\"other\":{\"tokens\":500,\"estimatedUsd\":0.001}}}}"))
            let cost = resolveProviderCost(rec: rec, providerName: "openrouter", legacyCost: 0.0)
            expect(cost == nil, "returns nil (unknown) when provider not in details, not legacy 0.0")
        }

        print("I2/R3: key-space mismatch — whitespace normalization")
        do {
            let rec = try! JSONDecoder().decode(UsageRecord.self, from: jsonData(
                "{\"providerUsage\":{\"openrouter\":{\"tokens\":1000,\"estimatedCostUsd\":0.0}}," +
                "\"details\":{\"providers\":{\" openrouter \":{\"tokens\":1000,\"estimatedUsd\":0.001}}}}"))
            let cost = resolveProviderCost(rec: rec, providerName: "openrouter", legacyCost: 0.0)
            expect(cost == 0.001, "normalizes whitespace and finds detail cost")
        }

        print("I2/R3: key-space mismatch — truncation normalization")
        do {
            let longKey = String(repeating: "a", count: 50)
            let truncatedKey = String(longKey.prefix(32))
            let rec = try! JSONDecoder().decode(UsageRecord.self, from: jsonData(
                "{\"providerUsage\":{\"\(truncatedKey)\":{\"tokens\":1000,\"estimatedCostUsd\":0.0}}," +
                "\"details\":{\"providers\":{\"\(longKey)\":{\"tokens\":1000,\"estimatedUsd\":0.002}}}}"))
            let cost = resolveProviderCost(rec: rec, providerName: truncatedKey, legacyCost: 0.0)
            expect(cost == 0.002, "normalizes truncation and finds detail cost")
        }

        print("I2/R3: key-space mismatch — empty → local normalization")
        do {
            let rec = try! JSONDecoder().decode(UsageRecord.self, from: jsonData(
                "{\"providerUsage\":{\"local\":{\"tokens\":1000,\"estimatedCostUsd\":0.0}}," +
                "\"details\":{\"providers\":{\"\":{\"tokens\":1000,\"estimatedUsd\":0.003}}}}"))
            let cost = resolveProviderCost(rec: rec, providerName: "local", legacyCost: 0.0)
            expect(cost == 0.003, "normalizes empty to local and finds detail cost")
        }

        print("I2/R3: duplicate normalized keys — no crash, conservative nil merge")
        do {
            // Two raw keys normalize to the same value: "nous" and " nous " → "nous"
            // One has a cost, the other is nil → merged must be nil (unknown), not the 0.05.
            // Before the uniquingKeysWith fix, this would crash with SIGTRAP (exit 133).
            let rec = try! JSONDecoder().decode(UsageRecord.self, from: jsonData(
                "{\"providerUsage\":{\"nous\":{\"tokens\":1000,\"estimatedCostUsd\":0.0}}," +
                "\"details\":{\"providers\":{" +
                "\"nous\":{\"tokens\":500,\"estimatedUsd\":0.05}," +
                "\" nous \":{\"tokens\":300,\"estimatedUsd\":null}" +
                "}}}"
            ))
            let cost = resolveProviderCost(rec: rec, providerName: "nous", legacyCost: 0.0)
            expect(cost == nil, "duplicate normalized keys merge conservatively → nil (not crash)")
        }

        print("I2/R3: duplicate normalized keys — both agree on cost")
        do {
            // A6 CORRECTION (audit t_d11f2784): colliding detail buckets are
            // DISJOINT PARTIAL SUMS (upstream add_detail accumulates each
            // bucket additively), so equal costs must SUM, not de-duplicate.
            // This test previously asserted the undercount (keep one 0.01).
            let rec = try! JSONDecoder().decode(UsageRecord.self, from: jsonData(
                "{\"providerUsage\":{\"openrouter\":{\"tokens\":1000,\"estimatedCostUsd\":0.0}}," +
                "\"details\":{\"providers\":{" +
                "\"openrouter\":{\"tokens\":500,\"estimatedUsd\":0.01}," +
                "\" openrouter \":{\"tokens\":300,\"estimatedUsd\":0.01}" +
                "}}}"
            ))
            let cost = resolveProviderCost(rec: rec, providerName: "openrouter", legacyCost: 0.0)
            expect(cost == 0.02, "equal-cost collision sums: 0.01 + 0.01 → 0.02, got \(cost.map { String($0) } ?? "nil")")
        }

        print("I2/R3: duplicate normalized keys — costs disagree → nil")
        do {
            let rec = try! JSONDecoder().decode(UsageRecord.self, from: jsonData(
                "{\"providerUsage\":{\"deepseek\":{\"tokens\":1000,\"estimatedCostUsd\":0.0}}," +
                "\"details\":{\"providers\":{" +
                "\"deepseek\":{\"tokens\":500,\"estimatedUsd\":0.02}," +
                "\" deepseek\":{\"tokens\":300,\"estimatedUsd\":0.03}" +
                "}}}"
            ))
            // A6 CORRECTION: unequal disjoint partial sums ADD (0.02 + 0.03 = 0.05);
            // the previous "disagree → nil" reading treated them as duplicate
            // observations, which the upstream accumulation model refutes.
            let cost = resolveProviderCost(rec: rec, providerName: "deepseek", legacyCost: 0.0)
            expect(cost == 0.05, "unequal-cost collision sums disjoint partials: 0.02 + 0.03 → 0.05, got \(cost.map { String($0) } ?? "nil")")
        }
        
        print("")
        // ---- Accessibility label: day age derivation ----
        print("I2: accessibility label — day age from updatedAt")
        do {
            // Test the actual dayAgeLabel function, not a re-implementation
            let cal = Calendar.current
            let now = Date()
            let label0 = dayAgeLabel(updatedAt: now)
            let label1 = dayAgeLabel(updatedAt: cal.date(byAdding: .day, value: -1, to: now)!)
            let label2 = dayAgeLabel(updatedAt: cal.date(byAdding: .day, value: -2, to: now)!)
            let label5 = dayAgeLabel(updatedAt: cal.date(byAdding: .day, value: -5, to: now)!)
            let labelNone = dayAgeLabel(updatedAt: nil)
            
            // Basic correctness
            expect(label0 == "today", "0 days → today")
            expect(label1 == "yesterday", "1 day → yesterday")
            expect(label2 == "2 days old", "2 days → 2 days old")
            expect(label5 == "5 days old", "5 days → 5 days old")
            expect(labelNone == "age unknown", "no record → age unknown")
            
            // Critical: aged records must NOT claim to be current
            expect(!label2.contains("today"), "2-day-old label must not contain 'today'")
            expect(!label2.contains("yesterday"), "2-day-old label must not contain 'yesterday'")
            expect(!label5.contains("today"), "5-day-old label must not contain 'today'")
            expect(!label5.contains("yesterday"), "5-day-old label must not contain 'yesterday'")
            expect(!labelNone.contains("today"), "missing record label must not contain 'today'")
            expect(!labelNone.contains("yesterday"), "missing record label must not contain 'yesterday'")
        }
        
        print("")
        // ---- Midnight boundary regression test ----
        print("I2: midnight boundary — record at 23:59, check at 00:01")
        do {
            // Create a fixed "now" at 2026-09-14 00:01
            let cal = Calendar.current
            var components = DateComponents()
            components.year = 2026
            components.month = 9
            components.day = 14
            components.hour = 0
            components.minute = 1
            let now = cal.date(from: components)!
            
            // Record timestamp: 2026-09-13 23:59 (2 minutes ago, but different calendar day)
            components.day = 13
            components.hour = 23
            components.minute = 59
            let recordTime = cal.date(from: components)!
            
            let label = dayAgeLabel(updatedAt: recordTime, now: now)
            
            // Must say "yesterday" (calendar day boundary), not "today" (elapsed time)
            expect(label == "yesterday", "midnight boundary: 23:59 record at 00:01 → yesterday, got \(label)")
        }

        print("")
        print("")
        // ---- A3: noStores state ----
        print("A3: collector noStores diagnostic → .noStores state")
        do {
            let m = await MainActor.run { () -> UsageModel in
                let ex = ScriptedExecutor([
                    CollectorOutcome(kind: .noStores("no Hermes Agent session store found"), elapsed: 0.05)
                ])
                return UsageModel(executor: ex, collectorTimeout: 5)
            }
            _ = await drainModel(m)
            if case .noStores = m.loadState { expect(true, "state .noStores") }
            else { expect(false, "state .noStores, got \(m.loadState)") }
            expect(m.record == nil, "no record retained")
            expect(m.menuBarWarning, "menu bar warns on noStores")
            expect(m.errorText?.contains("no Hermes") == true, "error text includes diagnostic")
        }

        print("A3: noStores AFTER success → stale with retained record")
        do {
            let m = await MainActor.run { () -> UsageModel in
                let ex = ScriptedExecutor([
                    CollectorOutcome(kind: .success(jsonData("{\"id\":\"hermes\",\"name\":\"Hermes Agent\",\"schemaVersion\":1,\"hasLocalStats\":true,\"todayTotalTokens\":99}")), elapsed: 0.05),
                    CollectorOutcome(kind: .noStores("no Hermes Agent session store found"), elapsed: 0.05),
                ])
                return UsageModel(executor: ex, collectorTimeout: 5)
            }
            _ = await drainModel(m)
            expect(m.loadState == .success, "first run succeeded")
            await MainActor.run { m.refresh() }
            _ = await drainModel(m)
            expect(m.isStale, "stale flag set after noStores refresh")
            expect(m.record?.todayTotalTokens == 99, "previous record retained")
            if case .stale = m.loadState { expect(true, "state .stale after noStores") }
            else { expect(false, "state .stale after noStores, got \(m.loadState)") }
        }

        // ---- A3: unreadable state (hasLocalStats=false + truncated=true) ----
        print("A3: hasLocalStats=false + truncated=true → .unreadable state")
        do {
            let m = await MainActor.run { () -> UsageModel in
                let ex = ScriptedExecutor([
                    CollectorOutcome(kind: .success(jsonData(
                        "{\"id\":\"hermes\",\"name\":\"Hermes Agent\",\"schemaVersion\":1,\"hasLocalStats\":false,\"details\":{\"truncated\":true}}")), elapsed: 0.05)
                ])
                return UsageModel(executor: ex, collectorTimeout: 5)
            }
            _ = await drainModel(m)
            if case .unreadable = m.loadState { expect(true, "state .unreadable") }
            else { expect(false, "state .unreadable, got \(m.loadState)") }
            expect(m.menuBarWarning, "menu bar warns on unreadable")
            // F2: do NOT store record — unreadable envelope is error, not data
            expect(m.record == nil, "no record stored for unreadable (F2)")
        }

        print("A3: unreadable AFTER success → stale with retained record")
        do {
            let m = await MainActor.run { () -> UsageModel in
                let ex = ScriptedExecutor([
                    CollectorOutcome(kind: .success(jsonData("{\"id\":\"hermes\",\"name\":\"Hermes Agent\",\"schemaVersion\":1,\"hasLocalStats\":true,\"todayTotalTokens\":77}")), elapsed: 0.05),
                    CollectorOutcome(kind: .success(jsonData("{\"id\":\"hermes\",\"name\":\"Hermes Agent\",\"schemaVersion\":1,\"hasLocalStats\":false,\"details\":{\"truncated\":true}}")), elapsed: 0.05),
                ])
                return UsageModel(executor: ex, collectorTimeout: 5)
            }
            _ = await drainModel(m)
            expect(m.loadState == .success, "first run succeeded")
            await MainActor.run { m.refresh() }
            _ = await drainModel(m)
            expect(m.isStale, "stale flag set after unreadable refresh")
            expect(m.record?.todayTotalTokens == 77, "previous record retained")
        }

        // ---- A3: genuine noData still works ----
        print("A3: genuine noData (hasLocalStats=false, truncated=false) still works")
        do {
            let m = await MainActor.run { () -> UsageModel in
                let ex = ScriptedExecutor([
                    CollectorOutcome(kind: .success(jsonData(
                        "{\"id\":\"hermes\",\"name\":\"Hermes Agent\",\"schemaVersion\":1,\"hasLocalStats\":false,\"details\":{\"truncated\":false}}")), elapsed: 0.05)
                ])
                return UsageModel(executor: ex, collectorTimeout: 5)
            }
            _ = await drainModel(m)
            expect(m.loadState == .noData, "state .noData")
            expect(!m.menuBarWarning, "menu bar does not warn on genuine noData")
        }

        // ---- A3: classify recognizes no-store diagnostic ----
        print("A3: CollectorRunner.classify recognizes no-store diagnostic")
        do {
            let o = CollectorRunner.classify(exitStatus: 1, timedOut: false, outputTruncated: false,
                                             data: Data(), stderrText: "hermes-usage: no Hermes Agent session store found (looked in /foo)", elapsed: 0.5)
            if case .noStores(let msg) = o.kind {
                expect(msg.contains("no Hermes Agent session store found"), "noStores diagnostic classified, got \(msg)")
            } else {
                expect(false, "expected .noStores, got \(o.kind)")
            }
        }

        print("A3: classify — other exit 1 still generic failure")
        do {
            let o = CollectorRunner.classify(exitStatus: 1, timedOut: false, outputTruncated: false,
                                             data: Data(), stderrText: "some other error", elapsed: 0.5)
            if case .failure = o.kind { expect(true, "other exit 1 is generic failure") }
            else { expect(false, "expected .failure, got \(o.kind)") }
        }

        // ---- A6: empty object rejected ----
        print("A6: empty object {} rejected, previous record retained as stale")
        do {
            let m = await MainActor.run { () -> UsageModel in
                let ex = ScriptedExecutor([
                    CollectorOutcome(kind: .success(jsonData("{\"id\":\"hermes\",\"name\":\"Hermes Agent\",\"schemaVersion\":1,\"hasLocalStats\":true,\"todayTotalTokens\":500}")), elapsed: 0.05),
                    CollectorOutcome(kind: .success(jsonData("{}")), elapsed: 0.05),
                ])
                return UsageModel(executor: ex, collectorTimeout: 5)
            }
            _ = await drainModel(m)
            expect(m.loadState == .success, "first load succeeds")
            expect(m.record?.todayTotalTokens == 500, "record has 500 tokens")
            await MainActor.run { m.refresh() }
            _ = await drainModel(m)
            expect(m.isStale, "after empty object, model is stale")
            expect(m.record?.todayTotalTokens == 500, "previous record retained (500 tokens)")
            if case .stale(let msg) = m.loadState {
                expect(msg.contains("not recognized") || msg.contains("unrecognized"), "stale message mentions unrecognized format, got \(msg)")
            } else {
                expect(false, "loadState should be .stale, got \(m.loadState)")
            }
        }

        print("A6: empty object {} rejected on first load → .unrecognized")
        do {
            let m = await MainActor.run { () -> UsageModel in
                let ex = ScriptedExecutor([
                    CollectorOutcome(kind: .success(jsonData("{}")), elapsed: 0.05)
                ])
                return UsageModel(executor: ex, collectorTimeout: 5)
            }
            _ = await drainModel(m)
            if case .unrecognized = m.loadState { expect(true, "state .unrecognized on first load") }
            else { expect(false, "state .unrecognized, got \(m.loadState)") }
            expect(m.record == nil, "no record stored for unrecognized")
            expect(m.menuBarWarning, "menu bar warns on unrecognized")
        }

        // A6: valid JSON without producer identity rejected
        print("A6: valid JSON without producer identity (no id/name) rejected")
        do {
            let m = await MainActor.run { () -> UsageModel in
                let ex = ScriptedExecutor([
                    CollectorOutcome(kind: .success(jsonData("{\"hasLocalStats\":true,\"todayTotalTokens\":100}")), elapsed: 0.05)
                ])
                return UsageModel(executor: ex, collectorTimeout: 5)
            }
            _ = await drainModel(m)
            if case .unrecognized = m.loadState { expect(true, "state .unrecognized without identity") }
            else { expect(false, "state .unrecognized, got \(m.loadState)") }
        }

        // A6: valid JSON with id/name but missing hasLocalStats rejected
        print("A6: valid JSON with id/name but missing hasLocalStats rejected")
        do {
            let m = await MainActor.run { () -> UsageModel in
                let ex = ScriptedExecutor([
                    CollectorOutcome(kind: .success(jsonData("{\"id\":\"hermes\",\"name\":\"Hermes Agent\",\"todayTotalTokens\":200}")), elapsed: 0.05)
                ])
                return UsageModel(executor: ex, collectorTimeout: 5)
            }
            _ = await drainModel(m)
            if case .unrecognized = m.loadState { expect(true, "state .unrecognized without hasLocalStats") }
            else { expect(false, "state .unrecognized, got \(m.loadState)") }
        }

        // A6: recovery after unrecognized
        print("A6: recovery after unrecognized → success")
        do {
            let m = await MainActor.run { () -> UsageModel in
                let ex = ScriptedExecutor([
                    CollectorOutcome(kind: .success(jsonData("{}")), elapsed: 0.05),
                    CollectorOutcome(kind: .success(jsonData("{\"id\":\"hermes\",\"name\":\"Hermes Agent\",\"schemaVersion\":1,\"hasLocalStats\":true,\"todayTotalTokens\":300}")), elapsed: 0.05),
                ])
                return UsageModel(executor: ex, collectorTimeout: 5)
            }
            _ = await drainModel(m)
            if case .unrecognized = m.loadState { expect(true, "first load unrecognized") }
            else { expect(false, "first load unrecognized, got \(m.loadState)") }
            await MainActor.run { m.refresh() }
            _ = await drainModel(m)
            expect(m.loadState == .success, "recovery succeeds")
            expect(m.record?.todayTotalTokens == 300, "recovered record has 300 tokens")
            expect(!m.isStale, "not stale after recovery")
        }

        // A6: valid accounts-only record (hasLocalStats=false, no local stats) accepted
        print("A6: valid accounts-only record (hasLocalStats=false, truncated=false) accepted")
        do {
            let m = await MainActor.run { () -> UsageModel in
                let ex = ScriptedExecutor([
                    CollectorOutcome(kind: .success(jsonData(
                        "{\"id\":\"hermes\",\"name\":\"Hermes Agent\",\"schemaVersion\":1,\"hasLocalStats\":false,\"details\":{\"truncated\":false}}")), elapsed: 0.05)
                ])
                return UsageModel(executor: ex, collectorTimeout: 5)
            }
            _ = await drainModel(m)
            expect(m.loadState == .noData, "accounts-only → .noData (no local stats)")
            expect(!m.menuBarWarning, "no warning for accounts-only")
        }

        // A6: wrong producer/version rejected
        print("A6: wrong producer (different id/name) rejected")
        do {
            let m = await MainActor.run { () -> UsageModel in
                let ex = ScriptedExecutor([
                    CollectorOutcome(kind: .success(jsonData("{\"id\":\"hermes\",\"name\":\"Hermes Agent\",\"schemaVersion\":1,\"hasLocalStats\":true,\"todayTotalTokens\":400}")), elapsed: 0.05),
                    // Fixture differs ONLY in id/name — keeps todayTotalTokens to isolate identity rejection
                    CollectorOutcome(kind: .success(jsonData("{\"id\":\"other-agent\",\"name\":\"Other Agent\",\"schemaVersion\":1,\"hasLocalStats\":true,\"todayTotalTokens\":400}")), elapsed: 0.05)
                ])
                return UsageModel(executor: ex, collectorTimeout: 5)
            }
            _ = await drainModel(m)
            // First load succeeds with valid producer
            expect(m.loadState == .success, "first valid load succeeds")
            expect(m.record?.todayTotalTokens == 400, "valid record has 400 tokens")
            // Trigger second refresh to consume the wrong-producer outcome
            await MainActor.run { m.refresh() }
            _ = await drainModel(m)
            // Second load with wrong producer is rejected
            expect(m.loadState == .stale("Usage format not recognized"), "wrong producer makes model stale")
            expect(m.record?.todayTotalTokens == 400, "previous valid record retained (400 tokens)")
        }

        // A6b: wrong name only (correct id, correct schemaVersion) rejected
        print("A6b: wrong name only rejected")
        do {
            let m = await MainActor.run { () -> UsageModel in
                let ex = ScriptedExecutor([
                    CollectorOutcome(kind: .success(jsonData("{\"id\":\"hermes\",\"name\":\"Hermes Agent\",\"schemaVersion\":1,\"hasLocalStats\":true,\"todayTotalTokens\":500}")), elapsed: 0.05),
                    CollectorOutcome(kind: .success(jsonData("{\"id\":\"hermes\",\"name\":\"Not Hermes\",\"schemaVersion\":1,\"hasLocalStats\":true,\"todayTotalTokens\":500}")), elapsed: 0.05)
                ])
                return UsageModel(executor: ex, collectorTimeout: 5)
            }
            _ = await drainModel(m)
            expect(m.loadState == .success, "valid load succeeds")
            await MainActor.run { m.refresh() }
            _ = await drainModel(m)
            expect(m.loadState == .stale("Usage format not recognized"), "wrong name makes model stale")
            expect(m.record?.todayTotalTokens == 500, "previous valid record retained")
        }

        // A6c: wrong schemaVersion (correct id, correct name) rejected
        print("A6c: wrong schemaVersion rejected")
        do {
            let m = await MainActor.run { () -> UsageModel in
                let ex = ScriptedExecutor([
                    CollectorOutcome(kind: .success(jsonData("{\"id\":\"hermes\",\"name\":\"Hermes Agent\",\"schemaVersion\":1,\"hasLocalStats\":true,\"todayTotalTokens\":600}")), elapsed: 0.05),
                    CollectorOutcome(kind: .success(jsonData("{\"id\":\"hermes\",\"name\":\"Hermes Agent\",\"schemaVersion\":99,\"hasLocalStats\":true,\"todayTotalTokens\":600}")), elapsed: 0.05)
                ])
                return UsageModel(executor: ex, collectorTimeout: 5)
            }
            _ = await drainModel(m)
            expect(m.loadState == .success, "valid load succeeds")
            await MainActor.run { m.refresh() }
            _ = await drainModel(m)
            expect(m.loadState == .stale("Usage format not recognized"), "unsupported schemaVersion makes model stale")
            expect(m.record?.todayTotalTokens == 600, "previous valid record retained")
        }

        // A6d: wrong id only (correct name, correct schemaVersion) rejected
        print("A6d: wrong id only rejected")
        do {
            let m = await MainActor.run { () -> UsageModel in
                let ex = ScriptedExecutor([
                    CollectorOutcome(kind: .success(jsonData("{\"id\":\"hermes\",\"name\":\"Hermes Agent\",\"schemaVersion\":1,\"hasLocalStats\":true,\"todayTotalTokens\":700}")), elapsed: 0.05),
                    CollectorOutcome(kind: .success(jsonData("{\"id\":\"not-hermes\",\"name\":\"Hermes Agent\",\"schemaVersion\":1,\"hasLocalStats\":true,\"todayTotalTokens\":700}")), elapsed: 0.05)
                ])
                return UsageModel(executor: ex, collectorTimeout: 5)
            }
            _ = await drainModel(m)
            expect(m.loadState == .success, "valid load succeeds")
            await MainActor.run { m.refresh() }
            _ = await drainModel(m)
            expect(m.loadState == .stale("Usage format not recognized"), "wrong id makes model stale")
            expect(m.record?.todayTotalTokens == 700, "previous valid record retained")
        }

        // B2: taskSortPriority
        print("B2: taskSortPriority")
        do {
            expect(taskSortPriority("other") == 100, "'other' has priority 100")
            expect(taskSortPriority("unknown") == 90, "'unknown' has priority 90")
            expect(taskSortPriority("ordinary") == 80, "'ordinary' has priority 80")
            expect(taskSortPriority("custom-task") == 0, "custom tasks have priority 0")
            expect(taskSortPriority("another-task") == 0, "custom tasks have priority 0")
        }

        // B2: taskLabel
        print("B2: taskLabel")
        do {
            expect(taskLabel("ordinary") == "Ordinary", "'ordinary' → 'Ordinary'")
            expect(taskLabel("unknown") == "Unknown", "'unknown' → 'Unknown'")
            expect(taskLabel("other") == "Other", "'other' → 'Other'")
            expect(taskLabel("custom-task") == "custom-task", "custom tasks pass through")
            expect(taskLabel("medical-consult") == "medical-consult", "custom tasks pass through")
        }

        // B3: formatRecordedCost
        print("B3: formatRecordedCost")
        do {
            expect(formatRecordedCost(nil) == "Recorded cost unavailable", "nil → 'Recorded cost unavailable'")
            let cost10 = formatRecordedCost(10.0)
            expect(cost10.contains("$10.00"), "10.0 → contains '$10.00'")
            expect(cost10.contains("database observation"), "10.0 → contains 'database observation'")
            expect(cost10.contains("not invoice reconciliation"), "10.0 → qualifies 'not invoice reconciliation'")
        }

        // B3: formatRowStatusBreakdown
        print("B3: formatRowStatusBreakdown")
        do {
            expect(formatRowStatusBreakdown(nil) == nil, "nil → nil")
            expect(formatRowStatusBreakdown([:]) == nil, "empty dict → nil")
            let mixed = formatRowStatusBreakdown(["estimated": 5, "actual": 3])
            expect(mixed?.contains("5 with estimated cost") == true, "mixed: contains '5 with estimated cost'")
            expect(mixed?.contains("3 with actual cost") == true, "mixed: contains '3 with actual cost'")
            let single = formatRowStatusBreakdown(["estimated": 10])
            expect(single == "10 with estimated cost", "single status formatted correctly")
            expect(formatRowStatusBreakdown(["unknown": 0, "estimated": 0]) == nil, "all-zero → nil")
        }

        // B3: formatCallAvailability
        print("B3: formatCallAvailability")
        do {
            expect(formatCallAvailability(calls: nil, unknownCallRows: nil) == "Calls unavailable", "nil calls → 'Calls unavailable'")
            expect(formatCallAvailability(calls: 100, unknownCallRows: nil) == "100 reported calls", "100 calls, no unknown → '100 reported calls'")
            let withUnknown = formatCallAvailability(calls: 50, unknownCallRows: 5)
            expect(withUnknown == "50 reported calls; call count unavailable for 5 usage rows", "50 calls with 5 unknown rows")
            let singular = formatCallAvailability(calls: 10, unknownCallRows: 1)
            expect(singular == "10 reported calls; call count unavailable for 1 usage row", "10 calls with 1 unknown row (singular)")
        }

        // F6: formatCallCoverageWarning
        print("F6: formatCallCoverageWarning")
        do {
            let singular = formatCallCoverageWarning(unknownCallRows: 1)
            expect(singular == "Call count unavailable for 1 usage row", "singular: 1 row")
            let plural = formatCallCoverageWarning(unknownCallRows: 5)
            expect(plural == "Call count unavailable for 5 usage rows", "plural: 5 rows")
            // Verify it matches the phrasing in formatCallAvailability
            let avail = formatCallAvailability(calls: 100, unknownCallRows: 3)
            expect(avail.contains("call count unavailable for 3 usage rows"), "matches formatCallAvailability phrasing")
        }

        // F2: repeated unreadable must stay .unreadable, not become false saved-results
        print("F2: repeated unreadable stays .unreadable (no false saved-results)")
        do {
            let m = await MainActor.run { () -> UsageModel in
                let ex = ScriptedExecutor([
                    CollectorOutcome(kind: .success(jsonData(
                        "{\"id\":\"hermes\",\"name\":\"Hermes Agent\",\"schemaVersion\":1,\"hasLocalStats\":false,\"details\":{\"truncated\":true}}")), elapsed: 0.05),
                    CollectorOutcome(kind: .success(jsonData(
                        "{\"id\":\"hermes\",\"name\":\"Hermes Agent\",\"schemaVersion\":1,\"hasLocalStats\":false,\"details\":{\"truncated\":true}}")), elapsed: 0.05),
                ])
                return UsageModel(executor: ex, collectorTimeout: 5)
            }
            _ = await drainModel(m)
            if case .unreadable = m.loadState { expect(true, "first unreadable → .unreadable") }
            else { expect(false, "first unreadable → .unreadable, got \(m.loadState)") }
            expect(m.record == nil, "no record after first unreadable")
            // Retry: second unreadable must still be .unreadable, not .stale
            await MainActor.run { m.refresh() }
            _ = await drainModel(m)
            if case .unreadable = m.loadState { expect(true, "second unreadable stays .unreadable (F2)") }
            else { expect(false, "second unreadable stays .unreadable (F2), got \(m.loadState)") }
            expect(m.record == nil, "still no record after repeated unreadable (F2)")
        }

        // F5: hasNilProviderCost detects nil cost in provider rows
        print("F5: hasNilProviderCost detects nil provider costs")
        do {
            let noProviders = try! JSONDecoder().decode(UsageRecord.self, from: jsonData(
                "{\"id\":\"hermes\",\"name\":\"Hermes Agent\",\"schemaVersion\":1,\"hasLocalStats\":true,\"details\":{\"totals\":{\"estimatedUsd\":1.5}}}"))
            expect(!hasNilProviderCost(noProviders), "no providerUsage → false")

            let allKnown = try! JSONDecoder().decode(UsageRecord.self, from: jsonData(
                "{\"id\":\"hermes\",\"name\":\"Hermes Agent\",\"schemaVersion\":1,\"hasLocalStats\":true," +
                "\"providerUsage\":{\"p1\":{\"tokens\":100,\"estimatedCostUsd\":0.5},\"p2\":{\"tokens\":50,\"estimatedCostUsd\":0.25}}}"))
            expect(!hasNilProviderCost(allKnown), "all providers have costs → false")

            let mixedCosts = try! JSONDecoder().decode(UsageRecord.self, from: jsonData(
                "{\"id\":\"hermes\",\"name\":\"Hermes Agent\",\"schemaVersion\":1,\"hasLocalStats\":true," +
                "\"providerUsage\":{\"p1\":{\"tokens\":100,\"estimatedCostUsd\":0.5},\"p2\":{\"tokens\":50,\"estimatedCostUsd\":null}}}"))
            expect(hasNilProviderCost(mixedCosts), "mixed costs (one nil) → true (F5)")

            let allNil = try! JSONDecoder().decode(UsageRecord.self, from: jsonData(
                "{\"id\":\"hermes\",\"name\":\"Hermes Agent\",\"schemaVersion\":1,\"hasLocalStats\":true," +
                "\"providerUsage\":{\"p1\":{\"tokens\":100},\"p2\":{\"tokens\":50}}}"))
            expect(hasNilProviderCost(allNil), "all providers nil cost → true (F5)")

            // F5 regression: nil detail with non-nil legacy zero. This is the exact
            // @ui-consultant reproducer — legacy says $0.00, detail says unobserved.
            // resolveProviderCost must return nil; hasNilProviderCost must fire.
            let nilDetailNonNilLegacy = try! JSONDecoder().decode(UsageRecord.self, from: jsonData(
                "{\"id\":\"hermes\",\"name\":\"Hermes Agent\",\"schemaVersion\":1,\"hasLocalStats\":true," +
                "\"details\":{\"totals\":{\"estimatedUsd\":1.46},\"providers\":{\"anthropic\":{\"estimatedUsd\":null}}}," +
                "\"providerUsage\":{\"anthropic\":{\"tokens\":100,\"estimatedCostUsd\":0.0}}}"))
            expect(hasNilProviderCost(nilDetailNonNilLegacy), "nil detail + non-nil legacy zero → true (F5 regression)")
            expect(resolveProviderCost(rec: nilDetailNonNilLegacy, providerName: "anthropic", legacyCost: 0.0) == nil, "resolveProviderCost returns nil for nil detail (F5)")

            // F5 invariant: displayed unavailable cost implies legend, EVEN when aggregate is known
            // Real-world fixture: Anthropic row shows "—" (nil detail), OpenRouter shows "$0.00" (known zero),
            // aggregate is $1.46 (known). Legend "— Cost unavailable; not zero" MUST still appear.
            let realWorldMixed = try! JSONDecoder().decode(UsageRecord.self, from: jsonData(
                "{\"id\":\"hermes\",\"name\":\"Hermes Agent\",\"schemaVersion\":1,\"hasLocalStats\":true," +
                "\"details\":{\"totals\":{\"estimatedUsd\":1.46},\"providers\":{\"anthropic\":{\"estimatedUsd\":null},\"openrouter\":{\"estimatedUsd\":0.0}}}," +
                "\"providerUsage\":{\"anthropic\":{\"tokens\":100,\"estimatedCostUsd\":0.0},\"openrouter\":{\"tokens\":200,\"estimatedCostUsd\":0.0}}}"))
            expect(hasNilProviderCost(realWorldMixed), "F5 invariant: any nil provider detail → legend shown (aggregate known, legacy zero)")
        }

        // F3: formatWorkloadAccessibilitySummary names unavailable values explicitly
        print("F3: formatWorkloadAccessibilitySummary")
        do {
            let allPresent = formatWorkloadAccessibilitySummary(
                (name: "ordinary", tokens: 12_600_000, calls: 234, estimatedUsd: 1.23))
            expect(allPresent == "Ordinary, 234 calls, 12.6M tokens, Cost $1.23",
                   "all present → '\(allPresent)'")

            let nilCalls = formatWorkloadAccessibilitySummary(
                (name: "unknown", tokens: 730_000, calls: nil, estimatedUsd: nil))
            expect(nilCalls == "Unknown, Calls not recorded, 730k tokens, Cost unavailable; not zero",
                   "nil calls+cost → '\(nilCalls)'")

            let nilTokens = formatWorkloadAccessibilitySummary(
                (name: "other", tokens: nil, calls: 5, estimatedUsd: 0.0))
            expect(nilTokens == "Other, 5 calls, Tokens not recorded, Cost $0.00",
                   "nil tokens, known zero cost → '\(nilTokens)'")

            let allNil = formatWorkloadAccessibilitySummary(
                (name: "some-task", tokens: nil, calls: nil, estimatedUsd: nil))
            expect(allNil == "some-task, Calls not recorded, Tokens not recorded, Cost unavailable; not zero",
                   "all nil → '\(allNil)'")

            // Explicit task strings pass through unchanged (B2)
            let explicit = formatWorkloadAccessibilitySummary(
                (name: "dr-smith-followup", tokens: 500, calls: 2, estimatedUsd: 0.05))
            expect(explicit.contains("dr-smith-followup"), "explicit task name passes through")
        }

        // B4: accessibility label for model rows
        print("B4: model row accessibility label")
        do {
            let full = ModelUsage(inputTokens: 1000, outputTokens: 500, cacheReadInputTokens: 200, cacheCreationInputTokens: 100)
            
            let axLabel = formatModelAccessibilityLabel(modelName: "gpt-4", mu: full)
            expect(axLabel.contains("gpt-4") && axLabel.contains("1,800 total"),
                   "accessibility label includes model and total → '\(axLabel)'")
            expect(axLabel.contains("Input 1,000") && axLabel.contains("Output 500"),
                   "accessibility label includes components")
            
            let allNil = ModelUsage(inputTokens: nil, outputTokens: nil, cacheReadInputTokens: nil, cacheCreationInputTokens: nil)
            let nilAxLabel = formatModelAccessibilityLabel(modelName: "claude", mu: allNil)
            // A7 CORRECTION (audit t_d11f2784): an all-nil model's zero total
            // is assumed, not observed — the AX label must name the absence,
            // never announce "0 total". This test previously expected "0 total".
            expect(nilAxLabel == "claude, token components not observed",
                   "all-nil model AX label names absence, not '0 total' → '\(nilAxLabel)'")
            expect(!nilAxLabel.contains("0 total"), "all-nil model AX never claims an observed zero")
            
            // aggregateReasoning helper
            let withReasoning = try! JSONDecoder().decode(UsageRecord.self, from: jsonData(
                "{\"id\":\"hermes\",\"name\":\"Hermes Agent\",\"schemaVersion\":1,\"hasLocalStats\":true," +
                "\"details\":{\"totals\":{\"reasoning\":12345}}}"))
            expect(aggregateReasoning(withReasoning) == 12345,
                   "aggregateReasoning: > 0 yields the value → \(aggregateReasoning(withReasoning) ?? -1)")
            
            let zeroReasoning = try! JSONDecoder().decode(UsageRecord.self, from: jsonData(
                "{\"id\":\"hermes\",\"name\":\"Hermes Agent\",\"schemaVersion\":1,\"hasLocalStats\":true," +
                "\"details\":{\"totals\":{\"reasoning\":0}}}"))
            expect(aggregateReasoning(zeroReasoning) == nil,
                   "aggregateReasoning: 0 yields nil → \(String(describing: aggregateReasoning(zeroReasoning)))")
            
            let missingReasoning = try! JSONDecoder().decode(UsageRecord.self, from: jsonData(
                "{\"id\":\"hermes\",\"name\":\"Hermes Agent\",\"schemaVersion\":1,\"hasLocalStats\":true," +
                "\"details\":{\"totals\":{\"tokens\":1000}}}"))
            expect(aggregateReasoning(missingReasoning) == nil,
                   "aggregateReasoning: missing yields nil → \(String(describing: aggregateReasoning(missingReasoning)))")
        }

        // B5: formatUsageReceipt
        print("B5: usage receipt formatter")
        do {
            let fullRec = try! JSONDecoder().decode(UsageRecord.self, from: jsonData(
                "{\"id\":\"hermes\",\"name\":\"Hermes Agent\",\"schemaVersion\":1,\"hasLocalStats\":true," +
                "\"updatedAt\":\"2026-09-14T12:00:00Z\",\"todayTotalTokens\":50000," +
                "\"details\":{\"scope\":\"all profiles\",\"coverage\":\"bounded local history\"," +
                "\"dailyAttribution\":\"last 7 days\"," +
                "\"totals\":{\"tokens\":1000000,\"calls\":500,\"estimatedUsd\":2.50}}," +
                "\"providerUsage\":{\"anthropic\":{\"tokens\":500000},\"openai\":{\"tokens\":500000}}}"))
            
            let receipt = formatUsageReceipt(fullRec, loadState: .success, launchScope: .appDefaultRoot)
            expect(receipt.contains("Hermes Usage Summary"), "receipt has header")
            expect(receipt.contains("2026-09-14"), "receipt has snapshot timestamp")
            expect(receipt.contains("all profiles") && receipt.contains("intended, not proven complete"),
                   "receipt has scope with qualifier")
            expect(receipt.contains("bounded local history"), "receipt has coverage")
            expect(receipt.contains("50,000") && receipt.contains("estimated"),
                   "receipt has today's estimate")
            expect(receipt.contains("1,000,000"), "receipt has recorded history")
            expect(receipt.contains("Reported calls: 500"), "receipt has calls")
            expect(receipt.contains("$2.50") && receipt.contains("not invoice reconciliation"),
                   "receipt has cost with qualifier")
            expect(receipt.contains("2 providers"), "receipt has provider count")
            expect(receipt.contains("last 7 days"), "receipt has daily attribution")
            expect(receipt.contains("local Hermes Agent session stores"), "receipt has data source")
            expect(receipt.contains("App version:"), "receipt carries the app's own version (t_b2280a32)")
            expect(!receipt.contains("/Users/") && !receipt.contains("account") && !receipt.contains("stderr"),
                   "receipt excludes sensitive paths/identifiers")
            
            // Verify failure states don't leak diagnostic details (paths, stderr, etc.)
            let pathLikeDiagnostic = "/Users/test/.local/share/hermes/session-store.db"
            let stderrLikeDiagnostic = "error: failed to open /var/log/hermes.log: Permission denied"
            
            let emptyRec = try! JSONDecoder().decode(UsageRecord.self, from: jsonData(
                "{\"id\":\"hermes\",\"name\":\"Hermes Agent\",\"schemaVersion\":1,\"hasLocalStats\":true}"))
            
            let noStoresReceipt = formatUsageReceipt(emptyRec, loadState: .noStores(pathLikeDiagnostic), launchScope: .appDefaultRoot)
            expect(noStoresReceipt.contains("no session stores found"), "noStores: status line present")
            expect(!noStoresReceipt.contains("/Users/") && !noStoresReceipt.contains(".db"),
                   "noStores: excludes path details")
            
            let unreadableReceipt = formatUsageReceipt(emptyRec, loadState: .unreadable(stderrLikeDiagnostic), launchScope: .appDefaultRoot)
            expect(unreadableReceipt.contains("could not be read"), "unreadable: status line present")
            expect(!unreadableReceipt.contains("/var/log") && !unreadableReceipt.contains("Permission denied"),
                   "unreadable: excludes stderr details")
            
            let unrecognizedReceipt = formatUsageReceipt(emptyRec, loadState: .unrecognized("unknown format at /tmp/data.json"), launchScope: .appDefaultRoot)
            expect(unrecognizedReceipt.contains("data format not recognized"), "unrecognized: status line present")
            expect(!unrecognizedReceipt.contains("/tmp/") && !unrecognizedReceipt.contains(".json"),
                   "unrecognized: excludes path details")
            
            let failedReceipt = formatUsageReceipt(emptyRec, loadState: .failed("exit code 1, stderr: \(stderrLikeDiagnostic)"), launchScope: .appDefaultRoot)
            expect(failedReceipt.contains("collection failed"), "failed: status line present")
            expect(!failedReceipt.contains("/var/log") && !failedReceipt.contains("Permission denied") && !failedReceipt.contains("stderr"),
                   "failed: excludes stderr and path details")
            
            let staleRec = try! JSONDecoder().decode(UsageRecord.self, from: jsonData(
                "{\"id\":\"hermes\",\"name\":\"Hermes Agent\",\"schemaVersion\":1,\"hasLocalStats\":true," +
                "\"updatedAt\":\"2026-09-13T10:00:00Z\"}"))
            
            let staleReceipt = formatUsageReceipt(staleRec, loadState: .stale("refresh failed: \(pathLikeDiagnostic)"), launchScope: .appDefaultRoot)
            expect(staleReceipt.contains("showing previous data"), "stale: status line present")
            expect(!staleReceipt.contains("/Users/") && !staleReceipt.contains("test"),
                   "stale: excludes path details")
            
            let noDataRec = try! JSONDecoder().decode(UsageRecord.self, from: jsonData(
                "{\"id\":\"hermes\",\"name\":\"Hermes Agent\",\"schemaVersion\":1,\"hasLocalStats\":true}"))
            
            let noDataReceipt = formatUsageReceipt(noDataRec, loadState: .noData, launchScope: .appDefaultRoot)
            expect(noDataReceipt.contains("no local data found"),
                   "no-data state reflected → '\(noDataReceipt.prefix(100))'")
        }

        // B5: stale receipt retains prior snapshot and leaks no diagnostic (model-level)
        print("B5: stale receipt retains prior snapshot and leaks no diagnostic (model-level)")
        do {
            let canaryMarker = "CANARY-XYZ-789"
            let syntheticPath = "/Users/synthetic-abc123/.hermes/session-store.db"
            let failingDiagnostic = "hermes-usage: no Hermes Agent session store found (looked in \(syntheticPath)) — \(canaryMarker)"
            
            let m = await MainActor.run { () -> UsageModel in
                let ex = ScriptedExecutor([
                    CollectorOutcome(kind: .success(jsonData(
                        "{\"id\":\"hermes\",\"name\":\"Hermes Agent\",\"schemaVersion\":1,\"hasLocalStats\":true," +
                        "\"updatedAt\":\"2026-09-14T08:30:00Z\",\"todayTotalTokens\":42000," +
                        "\"details\":{\"scope\":\"device\",\"coverage\":\"full\",\"dailyAttribution\":\"7-day\"," +
                        "\"totals\":{\"tokens\":150000,\"calls\":300,\"estimatedUsd\":1.25}," +
                        "\"truncated\":false}," +
                        "\"modelUsage\":{\"gpt-4\":{\"inputTokens\":50000,\"outputTokens\":25000,\"cacheReadInputTokens\":0,\"cacheCreationInputTokens\":0}}," +
                        "\"providerUsage\":{\"openai\":{\"estimatedCostUsd\":1.25}}}")), elapsed: 0.05),
                    CollectorOutcome(kind: .failure(failingDiagnostic), elapsed: 0.05),
                ])
                return UsageModel(executor: ex, collectorTimeout: 5)
            }
            
            // First refresh: success
            _ = await drainModel(m)
            expect(m.loadState == .success, "first load succeeded")
            expect(m.record?.todayTotalTokens == 42000, "first record has tokens")
            let firstUpdatedAt = m.record?.updatedAt
            expect(firstUpdatedAt != nil, "first record has updatedAt")
            
            // Second refresh: failure
            await MainActor.run { m.refresh() }
            _ = await drainModel(m)
            
            // Model retains previous record
            expect(m.isStale, "model is stale after failed refresh")
            expect(m.record != nil, "record retained after failure")
            expect(m.record?.todayTotalTokens == 42000, "retained record has original tokens")
            expect(m.record?.updatedAt == firstUpdatedAt, "retained record has original updatedAt")
            
            // Format receipt from stale state
            let receipt = formatUsageReceipt(m.record!, loadState: m.loadState, launchScope: .appDefaultRoot)
            
            // (a) names the stale condition
            expect(receipt.contains("showing previous data"),
                   "stale: receipt names stale condition → '\(receipt)'")
            
            // (b) retains prior snapshot's token values
            expect(receipt.contains("42,000"), "stale: retains token count")
            expect(receipt.contains("150,000"), "stale: retains total tokens")
            expect(receipt.contains("Reported calls: 300"), "stale: retains call count")
            
            // (c) keeps SNAPSHOT timestamp, not current time
            expect(receipt.contains("2026-09-14"), "stale: retains snapshot date")
            expect(!receipt.contains("now") && !receipt.contains("current time"),
                   "stale: does not substitute current time")
            
            // (d) diagnostic, path, canary appear NOWHERE
            expect(!receipt.contains(syntheticPath),
                   "stale: excludes synthetic path → path=\(syntheticPath)")
            expect(!receipt.contains(canaryMarker),
                   "stale: excludes canary marker → canary=\(canaryMarker)")
            expect(!receipt.contains("looked in"), "stale: excludes diagnostic phrasing")
            expect(!receipt.contains("synthetic-abc123"), "stale: excludes path components")
        }

        // ---- B6: Account quota snapshots ----
        print("B6: AccountSnapshot Codable — full record decodes")
        do {
            let json = """
            {"id":"hermes","name":"Hermes Agent","schemaVersion":1,"hasLocalStats":true,
             "accounts":[{"schemaVersion":1,"provider":"nous","scope":"platform","accountSelection":"auto",
               "fetchedAt":1726400000,"expiresAt":1726400600,"source":"hermes-quota-plugin",
               "plan":"pro","windows":[{"label":"5h window","usedPercent":45.2,"remainingPercent":54.8,"resetAt":1726418000}],
               "available":true,"status":"observed","accessStatus":"allowed","remainingUsd":12.50,"currency":"USD"}]}
            """
            let rec = try? JSONDecoder().decode(UsageRecord.self, from: jsonData(json))
            expect(rec?.accounts?.count == 1, "one account snapshot decoded")
            let snap = rec?.accounts?.first
            expect(snap?.provider == "nous", "provider = nous")
            expect(snap?.scope == "platform", "scope = platform")
            expect(snap?.windows.count == 1, "one window")
            expect(snap?.windows.first?.label == "5h window", "window label")
            expect(snap?.windows.first?.usedPercent == 45.2, "usedPercent = 45.2")
            expect(snap?.windows.first?.remainingPercent == 54.8, "remainingPercent = 54.8")
            expect(snap?.remainingUsd == 12.50, "remainingUsd = 12.50")
            expect(snap?.currency == "USD", "currency = USD")
            expect(snap?.available == true, "available = true")
            expect(snap?.accessStatus == "allowed", "accessStatus = allowed")
        }

        print("B6: AccountSnapshot Codable — nil accounts (older collector)")
        do {
            let json = """
            {"id":"hermes","name":"Hermes Agent","schemaVersion":1,"hasLocalStats":true}
            """
            let rec = try? JSONDecoder().decode(UsageRecord.self, from: jsonData(json))
            expect(rec?.accounts == nil, "nil accounts when field absent")
        }

        print("B6: AccountSnapshot Codable — empty array (no snapshots)")
        do {
            let json = """
            {"id":"hermes","name":"Hermes Agent","schemaVersion":1,"hasLocalStats":true,"accounts":[]}
            """
            let rec = try? JSONDecoder().decode(UsageRecord.self, from: jsonData(json))
            expect(rec?.accounts?.isEmpty == true, "empty array decodes as empty")
        }

        print("B6: AccountSnapshot Codable — forward-compatible (extra keys tolerated)")
        do {
            let json = """
            {"id":"hermes","name":"Hermes Agent","schemaVersion":1,"hasLocalStats":true,
             "accounts":[{"schemaVersion":1,"provider":"anthropic","scope":"platform","accountSelection":"auto",
               "fetchedAt":1726400000,"expiresAt":1726400600,"source":"hermes-quota-plugin",
               "plan":"pro","windows":[],"available":true,"status":"observed","accessStatus":"allowed",
               "futureField":{"x":1}}]}
            """
            let rec = try? JSONDecoder().decode(UsageRecord.self, from: jsonData(json))
            expect(rec?.accounts?.count == 1, "forward-compatible snapshot decoded")
        }

        print("B6: AccountSnapshot Codable — multiple providers")
        do {
            let json = """
            {"id":"hermes","name":"Hermes Agent","schemaVersion":1,"hasLocalStats":true,
             "accounts":[
               {"schemaVersion":1,"provider":"openai-codex","scope":"platform","accountSelection":"auto",
                 "fetchedAt":1726400000,"expiresAt":1726400600,"source":"hermes-quota-plugin",
                 "plan":"pro","windows":[{"label":"5h","usedPercent":10,"remainingPercent":90,"resetAt":1726418000}],
                 "available":true,"status":"observed","accessStatus":"unknown"},
               {"schemaVersion":1,"provider":"anthropic","scope":"platform","accountSelection":"auto",
                 "fetchedAt":1726400000,"expiresAt":1726400600,"source":"hermes-quota-plugin",
                 "plan":"pro","windows":[],"available":false,"status":"unavailable","accessStatus":"unknown"},
               {"schemaVersion":1,"provider":"nous","scope":"platform","accountSelection":"auto",
                 "fetchedAt":1726400000,"expiresAt":1726400600,"source":"hermes-quota-plugin",
                 "plan":"pro","windows":[{"label":"daily","usedPercent":75,"remainingPercent":25,"resetAt":null}],
                 "available":true,"status":"observed","accessStatus":"denied","remainingUsd":null,"currency":"USD"}
             ]}
            """
            let rec = try? JSONDecoder().decode(UsageRecord.self, from: jsonData(json))
            expect(rec?.accounts?.count == 3, "three provider snapshots decoded")
            let denied = rec?.accounts?.first(where: { $0.accessStatus == "denied" })
            expect(denied?.provider == "nous", "denied provider is nous")
            expect(denied?.remainingUsd == nil, "nous denied: remainingUsd nil")
            let codex = rec?.accounts?.first(where: { $0.provider == "openai-codex" })
            expect(codex?.windows.first?.resetAt != nil, "codex window has resetAt")
        }

        print("B6: isSnapshotFresh — fresh snapshot")
        do {
            let now = Date(timeIntervalSince1970: 1726400300)  // 300s after fetch, 300s before expiry
            let snap = AccountSnapshot(schemaVersion: 1, provider: "nous", scope: "platform",
                accountSelection: "auto", fetchedAt: 1726400000, expiresAt: 1726400600,
                source: "test", plan: "pro", windows: [], available: true,
                status: "observed", accessStatus: "allowed", remainingUsd: nil, currency: nil)
            expect(isSnapshotFresh(snap, now: now) == true, "snapshot fresh when within TTL")
        }

        print("B6: isSnapshotFresh — expired snapshot")
        do {
            let now = Date(timeIntervalSince1970: 1726400700)  // 100s past expiry
            let snap = AccountSnapshot(schemaVersion: 1, provider: "nous", scope: "platform",
                accountSelection: "auto", fetchedAt: 1726400000, expiresAt: 1726400600,
                source: "test", plan: "pro", windows: [], available: true,
                status: "observed", accessStatus: "allowed", remainingUsd: nil, currency: nil)
            expect(isSnapshotFresh(snap, now: now) == false, "snapshot expired when past TTL")
        }

        print("B6: isSnapshotFresh — exactly at expiry boundary")
        do {
            let now = Date(timeIntervalSince1970: 1726400600)  // exactly at expiresAt
            let snap = AccountSnapshot(schemaVersion: 1, provider: "anthropic", scope: "platform",
                accountSelection: "auto", fetchedAt: 1726400000, expiresAt: 1726400600,
                source: "test", plan: "pro", windows: [], available: true,
                status: "observed", accessStatus: "unknown", remainingUsd: nil, currency: nil)
            expect(isSnapshotFresh(snap, now: now) == false, "snapshot expired at exact boundary (nowEpoch < expiresAt, not <=)")
        }

        print("B6: snapshotFreshness — returns correct labels")
        do {
            let freshNow = Date(timeIntervalSince1970: 1726400100)  // 500s remaining (>5min)
            let snap = AccountSnapshot(schemaVersion: 1, provider: "nous", scope: "platform",
                accountSelection: "auto", fetchedAt: 1726400000, expiresAt: 1726400600,
                source: "test", plan: "pro", windows: [], available: true,
                status: "observed", accessStatus: "allowed", remainingUsd: nil, currency: nil)
            expect(snapshotFreshness(snap, now: freshNow) == "fresh", "fresh when >5min remaining, got \(snapshotFreshness(snap, now: freshNow))")

            let soonNow = Date(timeIntervalSince1970: 1726400420)  // 180s remaining (<5min)
            let soonResult = snapshotFreshness(snap, now: soonNow)
            expect(soonResult == "3m", "<5min → '3m', got \(soonResult)")

            let almostNow = Date(timeIntervalSince1970: 1726400580)  // 20s remaining
            let almostResult = snapshotFreshness(snap, now: almostNow)
            expect(almostResult == "<1m", "<1min → '<1m', got \(almostResult)")

            let expiredNow = Date(timeIntervalSince1970: 1726400700)
            expect(snapshotFreshness(snap, now: expiredNow) == "expired", "expired when past TTL")
        }

        print("B6: formatResetTime — relative labels")
        do {
            let now = Date(timeIntervalSince1970: 1726400000)
            expect(formatResetTime(1726400300, now: now) == "in 5m", "5min → 'in 5m'")
            expect(formatResetTime(1726400030, now: now) == "<1m", "<1min → '<1m'")
            expect(formatResetTime(1726407200, now: now) == "in 2h", "2h → 'in 2h'")
            expect(formatResetTime(1726572800, now: now) == "in 2d", "2d → 'in 2d'")
            expect(formatResetTime(nil, now: now) == "Reset time unavailable", "nil → Reset time unavailable")
            expect(formatResetTime(1726399900, now: now) == "reset passed", "past reset → 'reset passed'")
        }

        print("B6: isWindowResetPassed — detects expired windows")
        do {
            // Window with resetAt in the future
            let futureWindow = AccountWindow(label: "5h", usedPercent: 50, remainingPercent: 50, resetAt: 1726400600)
            let now = Date(timeIntervalSince1970: 1726400000)
            expect(isWindowResetPassed(futureWindow, now: now) == false, "future reset → not passed")

            // Window with resetAt in the past
            let pastWindow = AccountWindow(label: "5h", usedPercent: 75, remainingPercent: 25, resetAt: 1726400000)
            let laterNow = Date(timeIntervalSince1970: 1726400600)
            expect(isWindowResetPassed(pastWindow, now: laterNow) == true, "past reset → passed")

            // Window with nil resetAt
            let nilWindow = AccountWindow(label: "daily", usedPercent: 60, remainingPercent: 40, resetAt: nil)
            expect(isWindowResetPassed(nilWindow, now: laterNow) == false, "nil reset → not passed")

            // Window exactly at resetAt boundary
            let exactWindow = AccountWindow(label: "5h", usedPercent: 80, remainingPercent: 20, resetAt: 1726400000)
            let exactNow = Date(timeIntervalSince1970: 1726400000)
            expect(isWindowResetPassed(exactWindow, now: exactNow) == true, "exact boundary → passed (>= not >)")
        }

        print("B6: window crossing resetAt without recollection — stale percentage not shown")
        do {
            // Simulate a window that was valid at collection but crosses resetAt while popover is open
            let collectionTime = Date(timeIntervalSince1970: 1726400000)
            let window = AccountWindow(label: "5h", usedPercent: 75.5, remainingPercent: 24.5, resetAt: 1726400300)

            // Before reset: should show percentage
            expect(isWindowResetPassed(window, now: collectionTime) == false, "before reset: not passed")
            expect(formatResetTime(window.resetAt, now: collectionTime) == "in 5m", "before reset: 'in 5m'")

            // After reset (no recollection, same decoded copy): should NOT show stale 24.5%
            let postResetTime = Date(timeIntervalSince1970: 1726400600)
            expect(isWindowResetPassed(window, now: postResetTime) == true, "after reset: passed")
            expect(formatResetTime(window.resetAt, now: postResetTime) == "reset passed", "after reset: 'reset passed'")
            // The UI rendering logic checks isWindowResetPassed and shows "reset passed — awaiting re-observation"
            // instead of formatPercent(window.remainingPercent), preventing stale allowance display
        }

        print("B6: accountWindowAnnouncement — AX strings for all three branches (t_d5fa34be)")
        do {
            let now = Date(timeIntervalSince1970: 1726400000)

            // Branch 1: crossed reset (isWindowResetPassed true) — percentage must be absent
            let crossedWindow = AccountWindow(label: "5h", usedPercent: 75.5, remainingPercent: 24.5, resetAt: 1726400300)
            let postResetNow = Date(timeIntervalSince1970: 1726400600)
            let crossed = accountWindowAnnouncement(crossedWindow, now: postResetNow)
            expect(crossed == "5h reset passed, awaiting re-observation", "crossed reset → '<label> reset passed, awaiting re-observation'")
            expect(!crossed.contains("24.5%"), "crossed reset → no stale percentage in AX announcement")
            expect(!crossed.contains("%"), "crossed reset → no '%' anywhere in AX announcement")

            // Branch 2: nil resetAt — percentage present, reset time unavailable
            let nilWindow = AccountWindow(label: "daily", usedPercent: 60, remainingPercent: 40, resetAt: nil)
            let nilMsg = accountWindowAnnouncement(nilWindow, now: now)
            expect(nilMsg == "daily 40% remaining, reset time unavailable", "nil resetAt → '<label> N% remaining, reset time unavailable'")

            // Branch 3: normal in-window — percentage plus relative reset time
            let normalWindow = AccountWindow(label: "weekly", usedPercent: 62.3, remainingPercent: 37.7, resetAt: 1726400300)
            let normalMsg = accountWindowAnnouncement(normalWindow, now: now)
            expect(normalMsg == "weekly 37.7% remaining, resets in 5m", "normal → '<label> N% remaining, resets <formatResetTime>'")

            // Same window flips branch as `now` crosses resetAt — no stale % once passed
            expect(accountWindowAnnouncement(crossedWindow, now: now) == "5h 24.5% remaining, resets in 5m",
                "same window pre-reset announces percentage")
            expect(accountWindowAnnouncement(crossedWindow, now: postResetNow) == "5h reset passed, awaiting re-observation",
                "same window post-reset drops percentage")
        }

        print("B6: formatPercent — integer and decimal formatting")
        do {
            expect(formatPercent(0) == "0%", "0 → '0%'")
            expect(formatPercent(100) == "100%", "100 → '100%'")
            expect(formatPercent(45.0) == "45%", "45.0 → '45%' (integer)")
            expect(formatPercent(45.2) == "45.2%", "45.2 → '45.2%'")
            expect(formatPercent(99.9) == "99.9%", "99.9 → '99.9%'")
        }

        print("B6: accountProviderLabel — known providers")
        do {
            expect(accountProviderLabel("openai-codex") == "Codex", "openai-codex → Codex")
            expect(accountProviderLabel("anthropic") == "Anthropic", "anthropic → Anthropic")
            expect(accountProviderLabel("nous") == "Nous", "nous → Nous")
            expect(accountProviderLabel("openrouter") == "OpenRouter", "openrouter → OpenRouter")
            expect(accountProviderLabel("custom-provider") == "custom-provider", "unknown passes through")
        }

        print("B6: formatAccessStatus — all statuses")
        do {
            expect(formatAccessStatus("allowed", provider: "nous") == "Allowed", "allowed → Allowed")
            expect(formatAccessStatus("denied", provider: "nous") == "Access denied", "denied → Access denied")
            expect(formatAccessStatus("member-cap-exceeded", provider: "nous") == "Member cap exceeded", "member-cap-exceeded → Member cap exceeded")
            expect(formatAccessStatus("unknown", provider: "openai-codex") == "—", "unknown → em dash")
            expect(formatAccessStatus("something-new", provider: "anthropic") == "—", "unknown status → em dash")
        }

        print("B6: hasAccessRestriction — only denied/member-cap-exceeded")
        do {
            func makeSnap(access: String) -> AccountSnapshot {
                AccountSnapshot(schemaVersion: 1, provider: "nous", scope: "platform",
                    accountSelection: "auto", fetchedAt: 0, expiresAt: 600,
                    source: "test", plan: "pro", windows: [], available: true,
                    status: "observed", accessStatus: access, remainingUsd: nil, currency: nil)
            }
            expect(hasAccessRestriction(makeSnap(access: "denied")) == true, "denied → true")
            expect(hasAccessRestriction(makeSnap(access: "member-cap-exceeded")) == true, "member-cap-exceeded → true")
            expect(hasAccessRestriction(makeSnap(access: "allowed")) == false, "allowed → false")
            expect(hasAccessRestriction(makeSnap(access: "unknown")) == false, "unknown → false")
        }

        print("B6: accounts-only record lifecycle — hasLocalStats=false with accounts")
        do {
            let m = await MainActor.run { () -> UsageModel in
                let ex = ScriptedExecutor([
                    CollectorOutcome(kind: .success(jsonData(
                        "{\"id\":\"hermes\",\"name\":\"Hermes Agent\",\"schemaVersion\":1,\"hasLocalStats\":false," +
                        "\"accounts\":[{\"schemaVersion\":1,\"provider\":\"nous\",\"scope\":\"platform\",\"accountSelection\":\"auto\"," +
                        "\"fetchedAt\":1726400000,\"expiresAt\":1726400600,\"source\":\"test\"," +
                        "\"plan\":\"pro\",\"windows\":[],\"available\":true,\"status\":\"observed\",\"accessStatus\":\"allowed\"}]}")),
                    elapsed: 0.05)
                ])
                return UsageModel(executor: ex, collectorTimeout: 5)
            }
            _ = await drainModel(m)
            expect(m.loadState == .noData, "accounts-only → .noData (no local stats)")
            expect(m.record?.accounts?.count == 1, "accounts decodable even in noData")
            expect(m.record?.accounts?.first?.provider == "nous", "nous account present")
        }

        print("B6: stale record retains accounts snapshots")
        do {
            let m = await MainActor.run { () -> UsageModel in
                let ex = ScriptedExecutor([
                    CollectorOutcome(kind: .success(jsonData(
                        "{\"id\":\"hermes\",\"name\":\"Hermes Agent\",\"schemaVersion\":1,\"hasLocalStats\":true," +
                        "\"accounts\":[{\"schemaVersion\":1,\"provider\":\"anthropic\",\"scope\":\"platform\",\"accountSelection\":\"auto\"," +
                        "\"fetchedAt\":1726400000,\"expiresAt\":1726400600,\"source\":\"test\"," +
                        "\"plan\":\"pro\",\"windows\":[],\"available\":true,\"status\":\"observed\",\"accessStatus\":\"unknown\"}]}")),
                    elapsed: 0.05),
                    CollectorOutcome(kind: .failure("timeout"), elapsed: 0.05),
                ])
                return UsageModel(executor: ex, collectorTimeout: 5)
            }
            _ = await drainModel(m)
            expect(m.loadState == .success, "first load succeeds")
            await MainActor.run { m.refresh() }
            _ = await drainModel(m)
            expect(m.isStale, "stale after failed refresh")
            expect(m.record?.accounts?.count == 1, "accounts retained in stale record")
            expect(m.record?.accounts?.first?.provider == "anthropic", "retained account is anthropic")
        }

        print("B6: TTL constant matches collector")
        expect(accountQuotaTTL == 600, "accountQuotaTTL = 600s (matches quota_io.py)")

        // ---- Accuracy slice 1 (audit t_d11f2784): A1, A5, A6, A7 ----
        // Every test below asserts at the VALUE level and each would fail on
        // the pre-fix revision of HermesUsage.swift.

        print("A6: equal-cost provider-key collision sums additive buckets (0.01 + 0.01)")
        do {
            // Producer-shaped collision: two distinct detail keys sharing their
            // first 32 characters (add_group keeps 64, providerUsage keeps 32).
            let longA = String(repeating: "a", count: 40) + "-first"
            let longB = String(repeating: "a", count: 40) + "-second"
            let prefix = String(repeating: "a", count: 32)
            let rec = try! JSONDecoder().decode(UsageRecord.self, from: jsonData(
                "{\"providerUsage\":{\"\(prefix)\":{\"tokens\":2000,\"estimatedCostUsd\":0.0}}," +
                "\"details\":{\"providers\":{" +
                "\"\(longA)\":{\"tokens\":1000,\"estimatedUsd\":0.01}," +
                "\"\(longB)\":{\"tokens\":1000,\"estimatedUsd\":0.01}" +
                "}}}"
            ))
            // Pre-fix: resolver kept ONE bucket → 0.01 (undercount).
            let cost = resolveProviderCost(rec: rec, providerName: prefix, legacyCost: 0.0)
            expect(cost == 0.02, "long-name collision: merged cost sums to 0.02, got \(cost.map { String($0) } ?? "nil")")
        }

        print("A6: three-way collision and nil constituent")
        do {
            let longA = String(repeating: "b", count: 40) + "-1"
            let longB = String(repeating: "b", count: 40) + "-2"
            let longC = String(repeating: "b", count: 40) + "-3"
            let prefix = String(repeating: "b", count: 32)
            let threeWay = try! JSONDecoder().decode(UsageRecord.self, from: jsonData(
                "{\"providerUsage\":{\"\(prefix)\":{\"tokens\":3000,\"estimatedCostUsd\":0.0}}," +
                "\"details\":{\"providers\":{" +
                "\"\(longA)\":{\"estimatedUsd\":0.01}," +
                "\"\(longB)\":{\"estimatedUsd\":0.02}," +
                "\"\(longC)\":{\"estimatedUsd\":0.03}," +
                "}}}"
            ))
            // t_ee403c54: EXACT equality is deliberate. resolveProviderCost
            // folds colliding buckets in sorted-key order, so the sum is the
            // same left-to-right accumulation in every process: (0.01+0.02)
            // +0.03. Before the fold order was deterministic, Dictionary
            // iteration order — randomized per process by the hash seed —
            // sometimes paired the buckets as (0.02+0.03)+0.01, which is
            // 0.060000000000000005, and this == failed on 2 of 6 runs.
            // Do NOT add a tolerance: a band here would re-admit exactly
            // that nondeterminism as "passing".
            let c3 = resolveProviderCost(rec: threeWay, providerName: prefix, legacyCost: 0.0)
            expect(c3 == 0.06, "three-way collision: deterministic sorted-key fold (0.01+0.02)+0.03 → exactly 0.06, got \(c3.map { String($0) } ?? "nil")")

            let withNil = try! JSONDecoder().decode(UsageRecord.self, from: jsonData(
                "{\"providerUsage\":{\"\(prefix)\":{\"tokens\":3000,\"estimatedCostUsd\":0.0}}," +
                "\"details\":{\"providers\":{" +
                "\"\(longA)\":{\"estimatedUsd\":0.01}," +
                "\"\(longB)\":{\"estimatedUsd\":null}" +
                "}}}"
            ))
            let cn = resolveProviderCost(rec: withNil, providerName: prefix, legacyCost: 0.0)
            expect(cn == nil, "nil constituent → merged cost unknown (nil), got \(cn.map { String($0) } ?? "nil")")
        }

        // t_ee403c54: the deterministic fold must still handle a nil
        // constituent that SORTS FIRST — unknown-before-known exercises the
        // Double?? merge branch the three-way case never touches.
        do {
            let dNil = String(repeating: "d", count: 40) + "-1"
            let dTwo = String(repeating: "d", count: 40) + "-2"
            let dThree = String(repeating: "d", count: 40) + "-3"
            let dPrefix = String(repeating: "d", count: 32)
            let nilFirst = try! JSONDecoder().decode(UsageRecord.self, from: jsonData(
                "{\"providerUsage\":{\"\(dPrefix)\":{\"tokens\":3000,\"estimatedCostUsd\":0.0}}," +
                "\"details\":{\"providers\":{" +
                "\"\(dNil)\":{\"estimatedUsd\":null}," +
                "\"\(dTwo)\":{\"estimatedUsd\":0.02}," +
                "\"\(dThree)\":{\"estimatedUsd\":0.03}" +
                "}}}"
            ))
            let cnf = resolveProviderCost(rec: nilFirst, providerName: dPrefix, legacyCost: 0.0)
            expect(cnf == nil, "nil constituent sorted first still poisons the merged cost, got \(cnf.map { String($0) } ?? "nil")")
        }

        print("A6: collision sum capped at upstream's 1e12 accumulation limit")
        do {
            let longA = String(repeating: "c", count: 40) + "-1"
            let longB = String(repeating: "c", count: 40) + "-2"
            let prefix = String(repeating: "c", count: 32)
            let rec = try! JSONDecoder().decode(UsageRecord.self, from: jsonData(
                "{\"details\":{\"providers\":{" +
                "\"\(longA)\":{\"estimatedUsd\":9.0e11}," +
                "\"\(longB)\":{\"estimatedUsd\":9.0e11}" +
                "}}}"
            ))
            let cost = resolveProviderCost(rec: rec, providerName: prefix, legacyCost: nil)
            expect(cost == 1e12, "collision sum respects upstream min(1e12, ...) cap, got \(cost.map { String($0) } ?? "nil")")
        }

        print("A7: all-nil record never renders an observed zero")
        do {
            // Identity-valid envelope with NO numeric fields — accepted by
            // isValidRecord. Pre-fix: totals chip showed "0" via ?? 0 and the
            // model AX label announced "0 total".
            let rec = try! JSONDecoder().decode(UsageRecord.self, from: jsonData(
                "{\"id\":\"hermes\",\"name\":\"Hermes Agent\",\"schemaVersion\":1,\"hasLocalStats\":true}"
            ))
            // Today cell: nil todayTotalTokens must render "—" (compactCost
            // convention), never "0".
            let todayCell = rec.todayTotalTokens.map { compactTokens(Double($0)) } ?? "—"
            expect(todayCell == "—", "nil todayTotalTokens → '—', got '\(todayCell)'")

            // Totals chip: no detail totals AND no modelUsage → "—", never "0".
            let recorded = rec.details?.totals?.tokens
            let fallback: Int? = {
                guard rec.details?.totals == nil,
                      let models = rec.modelUsage,
                      models.values.contains(where: { $0.hasAnyComponent }) else { return nil }
                return models.values.map(\.totalTokens).reduce(0, +)
            }()
            let allTokens = recorded ?? fallback
            expect(allTokens == nil, "all-nil record: totals chip shows '—', never 0")

            // All-nil modelUsage values also must not enable the fallback.
            let recWithNilModels = try! JSONDecoder().decode(UsageRecord.self, from: jsonData(
                "{\"id\":\"hermes\",\"name\":\"Hermes Agent\",\"schemaVersion\":1,\"hasLocalStats\":true," +
                "\"modelUsage\":{\"ghost\":{\"inputTokens\":null,\"outputTokens\":null," +
                "\"cacheReadInputTokens\":null,\"cacheCreationInputTokens\":null}}}"
            ))
            let ghostFallback: Int? = {
                guard recWithNilModels.details?.totals == nil,
                      let models = recWithNilModels.modelUsage,
                      models.values.contains(where: { $0.hasAnyComponent }) else { return nil }
                return models.values.map(\.totalTokens).reduce(0, +)
            }()
            expect(ghostFallback == nil, "all-nil ModelUsage does not masquerade as an observed zero total")

            // Provider tokens: nil stays "—".
            let ghostProvider = ProviderUsage(tokens: nil, subscriptionTokens: nil, estimatedCostUsd: nil)
            let providerCell = ghostProvider.tokens.map { compactTokens(Double($0)) } ?? "—"
            expect(providerCell == "—", "nil provider tokens → '—', got '\(providerCell)'")
        }

        print("A7: genuine zero is preserved as zero (nil-vs-zero duality intact)")
        do {
            let todayZero = 0
            let cell = compactTokens(Double(todayZero))
            expect(cell == "0", "observed zero today tokens render '0', got '\(cell)'")
            let observedModel = ModelUsage(inputTokens: 0, outputTokens: 0, cacheReadInputTokens: 0, cacheCreationInputTokens: 0)
            expect(observedModel.hasAnyComponent, "all-zero ModelUsage counts as observed")
            let ax = formatModelAccessibilityLabel(modelName: "m", mu: observedModel)
            expect(ax.contains("0 total"), "observed all-zero model still announces its measured 0 → '\(ax)'")
            let recZeroTotal = try! JSONDecoder().decode(UsageRecord.self, from: jsonData(
                "{\"id\":\"hermes\",\"name\":\"Hermes Agent\",\"schemaVersion\":1,\"hasLocalStats\":true," +
                "\"details\":{\"totals\":{\"tokens\":0}}}"
            ))
            expect(recZeroTotal.details?.totals?.tokens == 0, "observed zero total decodes and stays zero")
        }

        // A7 (t_58805a08): the all-nil model ROW — the production view path.
        // The earlier A7 tests covered the totals chips and the AX formatter;
        // native verification found the model row itself still rendered a
        // right-hand "0" with four nil-coerced "0" components, and AXHelp
        // inherited "0 tokens" from the total Text's .help. These tests drive
        // the same production helpers the view calls, on the exact synthetic
        // fixture from the native verification record.
        do {
            let fixture = try! JSONDecoder().decode(UsageRecord.self, from: jsonData(
                "{\"id\":\"hermes\",\"name\":\"Hermes Agent\",\"schemaVersion\":1,\"hasLocalStats\":true," +
                "\"modelUsage\":{\"Synthetic absent model\":{}}," +
                "\"details\":{\"scope\":\"PAYLOAD_SCOPE_CANARY\",\"coverage\":\"bounded local history\",\"truncated\":false,\"totals\":{}}," +
                "\"accounts\":[]}"
            ))
            guard let mu = fixture.modelUsage?["Synthetic absent model"] else {
                expect(false, "fixture decodes with all-nil Synthetic absent model")
                return // unreachable in a passing run; satisfies the guard
            }
            expect(!mu.hasAnyComponent, "all-nil model is recognized as unobserved at the row boundary")

            // The recorded total the view feeds the row (allSortedModels
            // shape: mu.totalTokens == 0 for an all-nil model).
            let recordedTotal = mu.totalTokens
            expect(recordedTotal == 0, "all-nil recorded total is the assumed zero (input to the row helpers)")

            // Production presentation calls for the right-hand total.
            let totalText = modelRowTotalText(recordedTotal: recordedTotal, mu: mu)
            expect(totalText == "—", "all-nil model row total renders '—', got '\(totalText)'")
            let totalHelp = modelRowTotalHelp(recordedTotal: recordedTotal, mu: mu)
            expect(!totalHelp.contains("0 tokens"), "all-nil model row help carries no '0 tokens', got '\(totalHelp)'")
            expect(totalHelp == "Token components not observed", "all-nil model row help names the absence")

            // AXValue stays the A7 contract string.
            let ax = formatModelAccessibilityLabel(modelName: "Synthetic absent model", mu: mu)
            expect(ax == "Synthetic absent model, token components not observed", "AXValue unchanged by the row fix")

            // Preserved behavior 1: real observed zero stays numeric.
            let observedZero = ModelUsage(inputTokens: 0, outputTokens: 0, cacheReadInputTokens: 0, cacheCreationInputTokens: 0)
            expect(modelRowTotalText(recordedTotal: 0, mu: observedZero) == "0",
                   "observed all-zero model row total stays '0'")
            expect(modelRowTotalHelp(recordedTotal: 0, mu: observedZero) == "0 tokens",
                   "observed all-zero model row help stays '0 tokens'")

            // Preserved behavior 2: partially observed model keeps its numeric
            // total and component rendering path (hasAnyComponent true).
            let partial = ModelUsage(inputTokens: 1500, outputTokens: nil, cacheReadInputTokens: nil, cacheCreationInputTokens: nil)
            expect(modelRowTotalText(recordedTotal: 1500, mu: partial) == "1.5k",
                   "partially observed model keeps numeric total, got '\(modelRowTotalText(recordedTotal: 1500, mu: partial))'")
            expect(partial.hasAnyComponent, "partial model renders component rows, not the not-observed message")

            // Preserved behavior 3: row without a ModelUsage entry at all
            // (mu == nil) keeps the legacy numeric path.
            expect(modelRowTotalText(recordedTotal: 42, mu: nil) == "42", "mu==nil row keeps numeric total")
        }

        print("A5: quota-only record renders accounts section alongside empty local state")
        do {
            // Producer-valid quota-only payload: hasLocalStats=false with a
            // fresh account observation (expiresAt well past any test clock).
            let future = Int(Date().timeIntervalSince1970) + 3600
            let fetched = Int(Date().timeIntervalSince1970)
            let quotaOnlyJSON =
                "{\"id\":\"hermes\",\"name\":\"Hermes Agent\",\"schemaVersion\":1,\"hasLocalStats\":false," +
                "\"accounts\":[{\"schemaVersion\":1,\"provider\":\"anthropic\",\"scope\":\"account\"," +
                "\"accountSelection\":\"Hermes-resolved credential; may differ from this conversation; not a pool total\"," +
                "\"fetchedAt\":\(fetched),\"expiresAt\":\(future),\"source\":\"claude-code\"," +
                "\"plan\":\"pro\",\"windows\":[{\"label\":\"5h\",\"usedPercent\":40.0,\"remainingPercent\":60.0,\"resetAt\":\(future)}]," +
                "\"available\":true,\"status\":\"observed\",\"accessStatus\":\"allowed\"}]}"
            let rec = try! JSONDecoder().decode(UsageRecord.self, from: jsonData(quotaOnlyJSON))
            // The mainContent routing condition for A5: quota-only records must
            // show accountsSection. Pre-fix, the .noData branch rendered
            // emptySection ONLY — accountsSection was unreachable.
            let isQuotaOnly = rec.hasLocalStats == false && !(rec.accounts ?? []).isEmpty
            expect(isQuotaOnly, "fixture is a producer-valid quota-only record")
            // Mirror of the exact routing predicate added to mainContent:
            func quotaSectionReachable(_ rec: UsageRecord) -> Bool {
                if let accounts = rec.accounts, !accounts.isEmpty { return true }
                return false
            }
            expect(quotaSectionReachable(rec), "quota-only record reaches accountsSection (was unreachable pre-fix)")
            // The account itself must be fresh by the same predicate the view uses.
            let snap = rec.accounts!.first!
            expect(isSnapshotFresh(snap), "quota-only account snapshot is fresh")
            expect(snap.available && !snap.windows.isEmpty, "account carries an observable 5h window")
            // Window values survive intact end-to-end (value-level, not string-shape).
            expect(snap.windows.first?.remainingPercent == 60.0, "remainingPercent preserved at 60.0")
        }

        print("A1: scope label is measured from the launch environment, not asserted")
        do {
            // No HERMES_HOME → the app-selected default root label.
            expect(captureLaunchScope(environment: [:]) == .appDefaultRoot,
                   "absent HERMES_HOME → appDefaultRoot")
            // Present HERMES_HOME (any value, including empty) → inherited,
            // and the label must disclose it.
            expect(captureLaunchScope(environment: ["HERMES_HOME": "/Users/x/.hermes/profiles/turing"]) == .inheritedHermesHome,
                   "profile-scoped HERMES_HOME → inheritedHermesHome")
            expect(captureLaunchScope(environment: ["HERMES_HOME": ""]) == .inheritedHermesHome,
                   "empty-string HERMES_HOME still counts as inherited")
            // The two labels differ when the coverage differs (audit A1 verification).
            let defaultLabel = scopeDescription(launchScope: .appDefaultRoot)
            let inheritedLabel = scopeDescription(launchScope: .inheritedHermesHome)
            expect(defaultLabel != inheritedLabel, "scope labels differ between default and inherited roots")
            expect(defaultLabel.contains("All profiles"), "default label names all-profiles scope")
            expect(inheritedLabel.contains("inherited Hermes home"), "inherited label discloses the inherited root")
            // The receipt states the measured scope, never a bare intent claim.
            let rec = try! JSONDecoder().decode(UsageRecord.self, from: jsonData(
                "{\"id\":\"hermes\",\"name\":\"Hermes Agent\",\"schemaVersion\":1,\"hasLocalStats\":true," +
                "\"details\":{\"scope\":\"device\",\"coverage\":\"bounded local history\"}}"
            ))
            let receiptInherited = formatUsageReceipt(rec, loadState: .success, launchScope: .inheritedHermesHome)
            expect(receiptInherited.contains("Collected under: This Mac · inherited Hermes home (may not cover all profiles)"),
                   "receipt carries the measured (inherited) scope")
            expect(receiptInherited.contains("Scope: device (intended, not proven complete)"),
                   "receipt still separates the producer intent label from the measured scope")
            let receiptDefault = formatUsageReceipt(rec, loadState: .success, launchScope: .appDefaultRoot)
            expect(receiptDefault.contains("Collected under: This Mac · All profiles"),
                   "receipt carries the measured (default) scope")
        }

        print("A1 residual: emptySection scope caveat and store paths derive from the measured launch scope")
        do {
            // Production helpers the emptySection view body calls — the same
            // pattern as modelRowTotalText/Help (slice-1 A7): no local mirror
            // of the routing, so deleting or re-hardcoding the view helper
            // fails these assertions.
            let caveatDefault = emptySectionScopeCaveat(launchScope: .appDefaultRoot)
            expect(caveatDefault.contains(scopeDescription(launchScope: .appDefaultRoot)),
                   "default caveat embeds the shared scope description, got '\(caveatDefault)'")
            let caveatInherited = emptySectionScopeCaveat(launchScope: .inheritedHermesHome)
            expect(caveatInherited.contains(scopeDescription(launchScope: .inheritedHermesHome)),
                   "inherited caveat embeds the shared scope description, got '\(caveatInherited)'")
            // The pre-fix defect asserted the DEFAULT scope ("this device,
            // all profiles") unconditionally. The inherited label's own
            // "(may not cover all profiles)" is a disclaimer, not an
            // assertion — so assert on the defect's actual wording.
            expect(!caveatInherited.contains("this device"),
                   "inherited caveat must not carry the hardcoded 'this device' wording, got '\(caveatInherited)'")
            expect(!caveatInherited.contains(scopeDescription(launchScope: .appDefaultRoot)),
                   "inherited caveat must not embed the DEFAULT scope description, got '\(caveatInherited)'")
            expect(caveatDefault != caveatInherited,
                   "caveat differs between default and inherited scopes")
            expect(caveatDefault.contains("mid-scan"),
                   "caveat keeps the empty-file fallback warning")

            let pathsDefault = emptySectionStorePaths(launchScope: .appDefaultRoot)
            expect(pathsDefault == ["~/.hermes/state.db", "~/.hermes/profiles/*/state.db"],
                   "default store paths name the app root stores, got \(pathsDefault)")
            let pathsInherited = emptySectionStorePaths(launchScope: .inheritedHermesHome)
            expect(pathsInherited != pathsDefault,
                   "inherited store paths differ from default")
            expect(!pathsInherited.contains(where: { $0.hasPrefix("~/.hermes") }),
                   "inherited store paths must not name ~/.hermes as the source, got \(pathsInherited)")
        }

        // ---- Palette contrast invariant (t_9b863783) ----
        // Recompute WCAG relative-sRGB luminance for every palette token
        // against its appearance background. Text tokens must clear 4.5:1;
        // accent/graphic tokens must clear 3:1 (non-text threshold).
        // This replaces the former "assert ratio in a comment" approach.
        print("Palette: WCAG contrast invariant — all tokens vs their backgrounds")
        do {
            func srgbToLinear(_ c: Double) -> Double {
                let s = c / 255.0
                return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
            }
            func luminance(_ r: Double, _ g: Double, _ b: Double) -> Double {
                0.2126 * srgbToLinear(r) + 0.7152 * srgbToLinear(g) + 0.0722 * srgbToLinear(b)
            }
            func ratio(_ r1: Double, _ g1: Double, _ b1: Double, _ r2: Double, _ g2: Double, _ b2: Double) -> Double {
                let L1 = luminance(r1, g1, b1)
                let L2 = luminance(r2, g2, b2)
                let lighter = max(L1, L2)
                let darker = min(L1, L2)
                return (lighter + 0.05) / (darker + 0.05)
            }

            // Backgrounds
            let lightBg: (Double, Double, Double) = (0xF2, 0xF2, 0xF2)
            let darkBg: (Double, Double, Double) = (0x1E, 0x1E, 0x1E)

            // Text tokens — must clear 4.5:1
            struct TextToken { let name: String; let fg: (Double, Double, Double); let bg: (Double, Double, Double); let minRatio: Double }
            let textTokens: [TextToken] = [
                TextToken(name: "light primary #1D1D1F",    fg: (0x1D, 0x1D, 0x1F), bg: lightBg, minRatio: 4.5),
                TextToken(name: "light secondary #5A5A60",  fg: (0x5A, 0x5A, 0x60), bg: lightBg, minRatio: 4.5),
                TextToken(name: "light tertiary #6E6E73",   fg: (0x6E, 0x6E, 0x73), bg: lightBg, minRatio: 4.5),
                TextToken(name: "dark primary #FFFFFF",     fg: (0xFF, 0xFF, 0xFF), bg: darkBg, minRatio: 4.5),
                TextToken(name: "dark secondary #C7C7CC",   fg: (0xC7, 0xC7, 0xCC), bg: darkBg, minRatio: 4.5),
                TextToken(name: "dark tertiary #B0B0B8",    fg: (0xB0, 0xB0, 0xB8), bg: darkBg, minRatio: 4.5),
            ]
            for t in textTokens {
                let r = ratio(t.fg.0, t.fg.1, t.fg.2, t.bg.0, t.bg.1, t.bg.2)
                expect(r >= t.minRatio, "\(t.name) = \(String(format: "%.3f", r)):1 >= 4.5:1")
            }

            // Accent/graphic tokens — must clear 3:1 (non-text)
            // scoped* tokens now style supplementary glyphs only (t_40db1924).
            struct GraphicToken { let name: String; let fg: (Double, Double, Double); let bg: (Double, Double, Double); let minRatio: Double }
            let graphicTokens: [GraphicToken] = [
                GraphicToken(name: "light accent orange #B25E00", fg: (0xB2, 0x5E, 0x00), bg: lightBg, minRatio: 3.0),
                GraphicToken(name: "light accent green #0A6B2E",  fg: (0x0A, 0x6B, 0x2E), bg: lightBg, minRatio: 3.0),
                GraphicToken(name: "dark accent orange #FF9F0A",   fg: (0xFF, 0x9F, 0x0A), bg: darkBg, minRatio: 3.0),
                GraphicToken(name: "dark accent green #30D158",    fg: (0x30, 0xD1, 0x58), bg: darkBg, minRatio: 3.0),
                GraphicToken(name: "light scopedWarning #602900",     fg: (0x60, 0x29, 0x00), bg: lightBg, minRatio: 3.0),
                GraphicToken(name: "dark scopedWarning #FF9F0A",      fg: (0xFF, 0x9F, 0x0A), bg: darkBg, minRatio: 3.0),
                GraphicToken(name: "light scopedCopySuccess #004512", fg: (0x00, 0x45, 0x12), bg: lightBg, minRatio: 3.0),
                GraphicToken(name: "dark scopedCopySuccess #30D158",  fg: (0x30, 0xD1, 0x58), bg: darkBg, minRatio: 3.0),
            ]
            for t in graphicTokens {
                let r = ratio(t.fg.0, t.fg.1, t.fg.2, t.bg.0, t.bg.1, t.bg.2)
                expect(r >= t.minRatio, "\(t.name) = \(String(format: "%.3f", r)):1 >= 3:1 (graphic)")
            }
        }

        print("")
        print("\(passes) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
