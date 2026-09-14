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
            {"id":"hermes","name":"Hermes Agent","hasLocalStats":true,
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
                "{\"hasLocalStats\":false}"))
            expect(a.hasLocalStats == false, "explicit false decodes as false")
            let b = try! JSONDecoder().decode(UsageRecord.self, from: jsonData(
                "{\"hasLocalStats\":true,\"details\":{\"totals\":{\"calls\":0,\"estimatedUsd\":null}}}"))
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
                "{\"hasLocalStats\":true,\"futureField\":{\"x\":1}}"))
            expect(ok?.hasLocalStats == true, "forward-compatible decode")
        }

        // ---- Lifecycle: success path ----
        print("I2/R6: lifecycle — success sets .success")
        await MainActor.run {
            let ex = ScriptedExecutor([CollectorOutcome(kind: .success(jsonData(
                "{\"hasLocalStats\":true,\"todayTotalTokens\":42}")), elapsed: 0.1)])
            let m = UsageModel(executor: ex, collectorTimeout: 5)
            m.refresh() // already started once via init; force another
        }
        // (The init-triggered refresh consumed the scripted outcome; assert via state after drain.)
        do {
            let m = await MainActor.run { () -> UsageModel in
                let ex = ScriptedExecutor([CollectorOutcome(kind: .success(jsonData(
                    "{\"hasLocalStats\":true,\"todayTotalTokens\":42}")), elapsed: 0.1)])
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
                    "{\"hasLocalStats\":false}")), elapsed: 0.05)])
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
                    CollectorOutcome(kind: .success(jsonData("{\"hasLocalStats\":true,\"todayTotalTokens\":7}")), elapsed: 0.05),
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
                    CollectorOutcome(kind: .success(jsonData("{\"hasLocalStats\":true}")), elapsed: 0.05),
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
                    "{\"hasLocalStats\":true,\"details\":{\"truncated\":true,\"totals\":{\"unknownCallRows\":3}}}")), elapsed: 0.05)])
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
                    CollectorOutcome(kind: .success(jsonData("{\"hasLocalStats\":true,\"todayTotalTokens\":9}")), elapsed: 0.05),
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

        print("")
        print("\(passes) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
