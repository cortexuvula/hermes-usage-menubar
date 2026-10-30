// XCTest-free lifecycle test driver for R1/I2 (I2 commit adds the CI-wired
// runner; this file is compiled only for `swift test`, never into the app).
// Uses the real PythonCollectorExecutor against synthetic python scripts.
import Foundation

var failures = 0
var passes = 0

func expect(_ cond: Bool, _ label: String) {
    if cond { passes += 1; print("  ✓ \(label)") }
    else { failures += 1; print("  ✗ FAIL: \(label)") }
}

func writeScript(_ body: String) -> String {
    let dir = NSTemporaryDirectory() + "/hermes-r1-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let p = dir + "/collector.py"
    try? body.write(toFile: p, atomically: true, encoding: .utf8)
    return p
}

@main
struct R1Tests {
    static func main() {
        print("R1: oversized stdout (2 MiB, 32x pipe capacity)")
        do {
            let script = writeScript("""
            import sys
            sys.stdout.write('{"pad":"' + 'A' * (2*1024*1024) + '"}')
            sys.stdout.flush()
            """)
            let start = Date()
            let out = PythonCollectorExecutor(scriptPath: script)
                .run(timeout: 15, maxOutputBytes: CollectorRunner.maxOutputBytes,
                     maxErrorBytes: CollectorRunner.maxErrorBytes)
            let elapsed = Date().timeIntervalSince(start)
            if case .failure(let msg) = out.kind {
                expect(msg.contains("exceeded"), "classified as oversized: \(msg.prefix(80))")
            } else { expect(false, "expected failure for oversized output") }
            expect(elapsed < 15, "completed without deadlock (took \(String(format: "%.2f", elapsed))s)")
        }

        print("R1: heavy stderr (512 KiB) + normal stdout")
        do {
            let script = writeScript("""
            import sys
            sys.stderr.write('E' * (512*1024))
            sys.stderr.flush()
            sys.stdout.write('{"ok":true}')
            """)
            let start = Date()
            let out = PythonCollectorExecutor(scriptPath: script)
                .run(timeout: 15, maxOutputBytes: CollectorRunner.maxOutputBytes,
                     maxErrorBytes: CollectorRunner.maxErrorBytes)
            let elapsed = Date().timeIntervalSince(start)
            if case .success(let data) = out.kind {
                expect(String(data: data, encoding: .utf8) == "{\"ok\":true}", "stdout intact")
            } else { expect(false, "expected success despite heavy stderr") }
            expect(elapsed < 15, "no stderr deadlock (took \(String(format: "%.2f", elapsed))s)")
        }

        print("R1: child never exits (sleep forever)")
        do {
            let script = writeScript("""
            import time
            print('{"started":true}', flush=True)
            while True:
                time.sleep(1)
            """)
            let start = Date()
            let out = PythonCollectorExecutor(scriptPath: script)
                .run(timeout: 2, maxOutputBytes: CollectorRunner.maxOutputBytes,
                     maxErrorBytes: CollectorRunner.maxErrorBytes)
            let elapsed = Date().timeIntervalSince(start)
            if case .failure(let msg) = out.kind {
                expect(msg.contains("timed out"), "timeout surfaced: \(msg)")
            } else { expect(false, "expected timeout failure") }
            expect(elapsed < 8, "terminated promptly (took \(String(format: "%.2f", elapsed))s)")
        }

        print("R1: oversized stdout AND never exits — worst case")
        do {
            let script = writeScript("""
            import sys, time
            while True:
                sys.stdout.write('B' * 65536)
                sys.stdout.flush()
            """)
            let start = Date()
            let out = PythonCollectorExecutor(scriptPath: script)
                .run(timeout: 2, maxOutputBytes: CollectorRunner.maxOutputBytes,
                     maxErrorBytes: CollectorRunner.maxErrorBytes)
            let elapsed = Date().timeIntervalSince(start)
            if case .failure(let msg) = out.kind {
                expect(msg.contains("timed out"), "worst case still times out: \(msg)")
            } else { expect(false, "expected timeout in worst case") }
            expect(elapsed < 8, "no deadlock in worst case (took \(String(format: "%.2f", elapsed))s)")
        }

        print("R1: normal quick exit")
        do {
            let script = writeScript("""
            print('{"todayTotalTokens": 123}')
            """)
            let out = PythonCollectorExecutor(scriptPath: script)
                .run(timeout: 10, maxOutputBytes: CollectorRunner.maxOutputBytes,
                     maxErrorBytes: CollectorRunner.maxErrorBytes)
            if case .success(let data) = out.kind {
                expect(String(data: data, encoding: .utf8)?.contains("123") == true, "payload captured")
            } else { expect(false, "expected success") }
        }

        print("R1: nonzero exit with stderr message")
        do {
            let script = writeScript("""
            import sys
            print('boom', file=sys.stderr)
            sys.exit(3)
            """)
            let out = PythonCollectorExecutor(scriptPath: script)
                .run(timeout: 10, maxOutputBytes: CollectorRunner.maxOutputBytes,
                     maxErrorBytes: CollectorRunner.maxErrorBytes)
            if case .failure(let msg) = out.kind {
                expect(msg.contains("exit 3") && msg.contains("boom"), "exit code + stderr surfaced: \(msg)")
            } else { expect(false, "expected exit failure") }
        }

        print("R1: subsequent executor usable after each case (no leaked state)")
        do {
            let script = writeScript("print('{}')")
            let out = PythonCollectorExecutor(scriptPath: script)
                .run(timeout: 5, maxOutputBytes: CollectorRunner.maxOutputBytes,
                     maxErrorBytes: CollectorRunner.maxErrorBytes)
            if case .success(let d) = out.kind {
                expect(String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "{}", "fresh run after adversarial runs still succeeds")
            } else { expect(false, "expected success on fresh run") }
        }

        // t_8b4c98d0: the vendored collector's details.providers fold must
        // share the providerUsage key space (same clean_provider normalizer,
        // cap MAX_MODELS=64). Runs the REAL vendored collector as a subprocess
        // against a synthetic HERMES_HOME exercising the three memo shapes:
        //   L  (blank billing_provider, KNOWN cost)  — must key "local"
        //   R33 (named providers ranked 33-64)        — must survive the fold
        //   U  (named provider, cost never observed)  — must stay nil
        // and then asserts the app-side fold over the decoded record: rows
        // resolve their real cost, and the totals chip is unqualified when
        // every contributor's cost is known (was: "—" rows + false "≥ $X").
        print("t_8b4c98d0: collector details.providers key space == providerUsage (L/R33/U)")
        do {
            let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            let collectorPath = repoRoot.appendingPathComponent(
                "build/HermesUsage.app/Contents/Resources/collector/hermes-usage.py").path
            expect(FileManager.default.fileExists(atPath: collectorPath),
                   "vendored collector present at \(collectorPath)")

            func collectorRecord(withGhost: Bool) -> UsageRecord? {
                let script = writeScript("""
                import os, runpy, sqlite3, sys, tempfile, time
                home = tempfile.mkdtemp(prefix="hu-r1-t8b4c98d0-")
                conn = sqlite3.connect(os.path.join(home, "state.db"))
                conn.execute("CREATE TABLE session_model_usage (session_id TEXT, model TEXT, billing_provider TEXT, billing_mode TEXT, input_tokens INTEGER, output_tokens INTEGER, cache_read_tokens INTEGER, cache_write_tokens INTEGER, reasoning_tokens INTEGER, estimated_cost_usd REAL, actual_cost_usd REAL, cost_status TEXT, first_seen REAL, last_seen REAL, api_call_count INTEGER, task TEXT)")
                now = time.time()
                rows = [("sL", "", 100, 1.23, "estimated")]
                rows += [("sr" + str(i), "p" + str(i).zfill(2), 10000 - i * 100, 0.10, "estimated") for i in range(1, 41)]
                include_ghost = \(withGhost ? "True" : "False")
                if include_ghost:
                    rows += [("sU", "ghost", 500, None, "unknown")]
                for sid, bp, inp, est, status in rows:
                    conn.execute("INSERT INTO session_model_usage VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                                 (sid, "m", bp, "", inp, 100, 0, 0, 0, est, None, status, now - 7200, now, 1, None))
                conn.commit(); conn.close()
                os.environ["HERMES_HOME"] = home
                sys.argv = ["hermes-usage.py", "--force"]
                runpy.run_path("\(collectorPath)", run_name="__main__")
                """)
                let out = PythonCollectorExecutor(scriptPath: script)
                    .run(timeout: 30, maxOutputBytes: CollectorRunner.maxOutputBytes,
                         maxErrorBytes: CollectorRunner.maxErrorBytes)
                guard case .success(let data) = out.kind else { return nil }
                return try? JSONDecoder().decode(UsageRecord.self, from: data)
            }

            // Mixed store: L + R33 + genuine-unknown ghost.
            if let rec = collectorRecord(withGhost: true) {
                let pu = Set((rec.providerUsage ?? [:]).keys)
                let det = rec.details?.providers ?? [:]
                expect(pu == Set(det.keys),
                       "details.providers keys == providerUsage keys (\(det.count) buckets)")
                expect(det["local"] != nil && det["unknown"] == nil,
                       "blank billing_provider keys 'local' in details, not 'unknown'")
                expect(det["other"] == nil, "no 'other' collapse below the 64 cap")
                expect(abs((det["local"]?.estimatedUsd ?? -1) - 1.23) < 0.005,
                       "L: local detail cost 1.23, got \(det["local"]?.estimatedUsd ?? -1)")
                expect(abs((det["p40"]?.estimatedUsd ?? -1) - 0.10) < 0.005,
                       "R33: rank-40 provider present with real cost, got \(det["p40"]?.estimatedUsd ?? -1)")
                expect(det["ghost"]?.estimatedUsd == nil,
                       "U: genuine-unknown provider keeps estimatedUsd nil")
                expect(abs((resolveProviderCost(rec: rec, providerName: "local", legacyCost: 1.23) ?? -1) - 1.23) < 0.005,
                       "app fold: local row resolves its real cost (was —)")
                expect(abs((resolveProviderCost(rec: rec, providerName: "p40", legacyCost: 0.10) ?? -1) - 0.10) < 0.005,
                       "app fold: rank-40 row resolves its real cost (was —)")
                expect(hasNilProviderCost(rec), "mixed store still qualifies (ghost is genuinely unknown)")
                expect(totalsCostChipText(rec).hasPrefix("≥ "), "mixed store chip qualified")
                let lsr = rec.details?.totals?.latestStatusRows
                expect(lsr?["unknown"] == 1, "latestStatusRows unchanged: 1 unknown row, got \(lsr?["unknown"] ?? -1)")
            } else { expect(false, "mixed-store collector run produced no decodable record") }

            // Clean store: L + R33 only — every contributor's cost known.
            if let rec = collectorRecord(withGhost: false) {
                expect(!hasNilProviderCost(rec),
                       "clean store: no nil-cost provider — false qualification gone (was 11 false positives)")
                expect(totalsCostChipText(rec) == "$5.23",
                       "clean store chip unqualified $5.23, got \(totalsCostChipText(rec))")
            } else { expect(false, "clean-store collector run produced no decodable record") }
        }

        print("")
        print("\(passes) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
