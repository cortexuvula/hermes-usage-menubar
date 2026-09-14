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
            // Two raw keys normalize to same value, both have same cost → keep it.
            let rec = try! JSONDecoder().decode(UsageRecord.self, from: jsonData(
                "{\"providerUsage\":{\"openrouter\":{\"tokens\":1000,\"estimatedCostUsd\":0.0}}," +
                "\"details\":{\"providers\":{" +
                "\"openrouter\":{\"tokens\":500,\"estimatedUsd\":0.01}," +
                "\" openrouter \":{\"tokens\":300,\"estimatedUsd\":0.01}" +
                "}}}"
            ))
            let cost = resolveProviderCost(rec: rec, providerName: "openrouter", legacyCost: 0.0)
            expect(cost == 0.01, "duplicate keys with matching costs → keep the known cost")
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
            let cost = resolveProviderCost(rec: rec, providerName: "deepseek", legacyCost: 0.0)
            expect(cost == nil, "duplicate keys with disagreeing costs → nil (conservative)")
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
            expect(m.record != nil, "record stored for context")
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
                    CollectorOutcome(kind: .success(jsonData("{\"id\":\"other-agent\",\"name\":\"Other Agent\",\"schemaVersion\":1,\"hasLocalStats\":true}")), elapsed: 0.05)
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

        print("")
        print("\(passes) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
