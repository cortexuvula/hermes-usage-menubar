// t_c9ec490a: About-panel version identity tests. Compiled with the
// library portion of the app (HermesUsage.swift, WITHOUT the @main file).
// Drives AppVersion's three paths — release, untagged/dev, plist-read
// failure — with the EXACT rendered strings asserted, plus the per-field
// About panel display strings and the t_b2280a32 guard-parity edges
// (missing keys, empty strings, wrong types, partial identity).
import Foundation

var failures = 0
var passes = 0

func expect(_ cond: Bool, _ label: String) {
    if cond { passes += 1; print("  ✓ \(label)") }
    else { failures += 1; print("  ✗ FAIL: \(label)") }
}

@main
struct AboutVersionTests {
    static func main() {
        print("About version identity: release path")
        do {
            let release = AppVersion(infoDictionary: [
                "CFBundleShortVersionString": "1.2.3",
                "CFBundleVersion": "77",
            ])
            expect(release.description == "1.2.3 (build 77)",
                   "release description is exactly '1.2.3 (build 77)'")
            expect(release.isAvailable, "release identity is available")
            expect(!release.isDevBuild, "release is not a dev build")
            expect(release.shortVersionDisplay == "1.2.3",
                   "release panel Version field is exactly '1.2.3'")
            expect(release.buildDisplay == "77",
                   "release panel Build field is exactly '77'")
            expect(release.statusDisplay == "Release",
                   "release panel Status field is exactly 'Release'")
        }

        print("About version identity: untagged/dev path")
        do {
            // build.sh stamps 0.0.0 + a derived build number when no tag
            // exists — the panel must keep that honest, never dress a dev
            // build up as a release.
            let dev = AppVersion(infoDictionary: [
                "CFBundleShortVersionString": "0.0.0",
                "CFBundleVersion": "412",
            ])
            expect(dev.description == "0.0.0 (build 412)",
                   "dev description is exactly '0.0.0 (build 412)'")
            expect(dev.isAvailable, "dev identity is available")
            expect(dev.isDevBuild, "0.0.0 stamp marks the build as dev")
            expect(dev.shortVersionDisplay == "0.0.0",
                   "dev panel Version field is exactly '0.0.0' (not a release number)")
            expect(dev.buildDisplay == "412",
                   "dev panel Build field is the derived build number '412'")
            expect(dev.statusDisplay == "Development build (untagged)",
                   "dev panel Status field says 'Development build (untagged)'")
        }

        print("About version identity: plist-read failure path")
        do {
            let missing = AppVersion(infoDictionary: nil)
            expect(missing.description == "version unavailable",
                   "nil plist description is exactly 'version unavailable'")
            expect(!missing.isAvailable, "nil plist identity is unavailable")
            expect(!missing.isDevBuild, "nil plist never claims dev status")
            expect(missing.shortVersionDisplay == "version unavailable",
                   "nil plist panel Version field is 'version unavailable' (not empty)")
            expect(missing.buildDisplay == "version unavailable",
                   "nil plist panel Build field is 'version unavailable' (not empty)")
            expect(missing.statusDisplay == "version unavailable",
                   "nil plist panel Status field is 'version unavailable' (not empty)")
        }

        print("About version identity: guard-parity edges (t_b2280a32)")
        do {
            let noKeys = AppVersion(infoDictionary: [
                "CFBundleName": "Hermes Usage",
                "CFBundleIdentifier": "ca.andrehugo.hermes-usage",
            ])
            expect(noKeys.description == "version unavailable",
                   "plist without version keys renders 'version unavailable'")

            let empty = AppVersion(infoDictionary: [
                "CFBundleShortVersionString": "",
                "CFBundleVersion": "",
            ])
            expect(empty.description == "version unavailable",
                   "empty string values render 'version unavailable'")
            expect(empty.shortVersionDisplay == "version unavailable",
                   "empty Version field renders 'version unavailable' (never empty string)")

            // Original guard required BOTH fields; identity stays unavailable
            // when either one is missing.
            let noBuild = AppVersion(infoDictionary: [
                "CFBundleShortVersionString": "1.2.3",
            ])
            expect(noBuild.description == "version unavailable",
                   "short version without build renders 'version unavailable'")
            let noShort = AppVersion(infoDictionary: [
                "CFBundleVersion": "77",
            ])
            expect(noShort.description == "version unavailable",
                   "build without short version renders 'version unavailable'")
            expect(!noShort.isAvailable, "partial identity is unavailable")

            // Non-string plist values must not leak through the cast.
            let wrongType = AppVersion(infoDictionary: [
                "CFBundleShortVersionString": 1,
                "CFBundleVersion": 2,
            ])
            expect(wrongType.description == "version unavailable",
                   "non-string plist values render 'version unavailable'")
        }

        print("")
        print("\(passes) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
