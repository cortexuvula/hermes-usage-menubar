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

        print("")
        print("\(passes) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
