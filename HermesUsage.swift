import SwiftUI
import AppKit

// MARK: - Models (mirrors collector/hermes-usage.py JSON record)

struct UsageRecord: Codable {
    let id: String?
    let name: String?
    let schemaVersion: Int?
    let updatedAt: String?
    let hasLocalStats: Bool?
    let todayPrompts: Int?
    let todaySessions: Int?
    let todayTotalTokens: Int?
    let todayTokensByModel: [String: Int]?
    let recentDays: [RecentDay]?
    let totalPrompts: Int?
    let totalSessions: Int?
    let activeDays: Int?
    let modelUsage: [String: ModelUsage]?
    let providerUsage: [String: ProviderUsage]?
    let details: Details?
    /// B6: Account quota snapshots from collector. Empty array means no
    /// snapshot available (not that plugin is uninstalled or access denied).
    /// Nullable to handle records from older collectors.
    let accounts: [AccountSnapshot]?
}

struct RecentDay: Codable {
    let date: String
    let messageCount: Int
}

struct ModelUsage: Codable {
    let inputTokens: Int?
    let outputTokens: Int?
    let cacheReadInputTokens: Int?
    let cacheCreationInputTokens: Int?
}

struct ProviderUsage: Codable {
    let tokens: Int?
    let subscriptionTokens: Int?
    let estimatedCostUsd: Double?
}

struct Details: Codable {
    let totals: Totals?
    let truncated: Bool?
    /// Per-provider detail buckets with nullable cost fields (R3).
    /// Keyed by cleaned provider name, matching providerUsage keys.
    let providers: [String: ProviderDetail]?
    /// B2: Per-task detail buckets. Keys are collector-generated labels
    /// (e.g., "ordinary", "unknown", "other") or explicit task strings.
    /// Nullable to handle records from older collectors or missing data.
    let tasks: [String: ProviderDetail]?
    /// B5: Scope and coverage metadata from collector.
    /// scope: "device" (intended scope, not proven complete coverage)
    /// coverage: "bounded local history"
    /// dailyAttribution: description of how daily totals are attributed
    let scope: String?
    let coverage: String?
    let dailyAttribution: String?
}

// MARK: - B6: Account quota snapshots

/// B6: Per-provider quota window from collector's account snapshot.
/// Mirrors quota_io.py window shape: {label, usedPercent, remainingPercent, resetAt}.
struct AccountWindow: Codable {
    let label: String
    let usedPercent: Double
    let remainingPercent: Double
    let resetAt: Double?  // Unix timestamp, nil if no reset scheduled
}

/// B6: Account quota snapshot from collector.
/// Mirrors quota_io.py record shape with TTL-based freshness (600s).
/// Preserves distinct states: unknown, zero, unavailable, denied, expired.
struct AccountSnapshot: Codable {
    let schemaVersion: Int
    let provider: String
    let scope: String
    let accountSelection: String
    let fetchedAt: Double
    let expiresAt: Double
    let source: String
    let plan: String
    let windows: [AccountWindow]
    let available: Bool
    let status: String  // "observed" or "unavailable"
    let accessStatus: String  // "unknown", "allowed", "denied", "member-cap-exceeded"
    let remainingUsd: Double?  // Only for nous provider with currency="USD"
    let currency: String?
}

/// Mirrors the collector's new_detail_bucket() for per-provider groups.
/// Nullable fields preserve "not observed" vs "observed zero" (R3).
struct ProviderDetail: Codable {
    let rows: Int?
    let calls: Int?
    let unknownCallRows: Int?
    let tokens: Int?
    let reasoning: Int?
    let cacheRead: Int?
    let estimatedUsd: Double?
    let actualUsd: Double?
    let latestStatusRows: [String: Int]?
}

struct Totals: Codable {
    let rows: Int?
    let calls: Int?
    let unknownCallRows: Int?
    let tokens: Int?
    let reasoning: Int?
    let cacheRead: Int?
    let estimatedUsd: Double?
    let actualUsd: Double?
    /// B3: Row-status breakdown for accounting evidence.
    /// Keys: "estimated", "actual", "included", "unknown".
    let latestStatusRows: [String: Int]?
}

// MARK: - Formatting helpers

func compactTokens(_ n: Double) -> String {
    if n >= 1_000_000 { return String(format: "%.1fM", n / 1_000_000) }
    if n >= 10_000 { return String(format: "%.0fk", n / 1_000) }
    if n >= 1_000 { return String(format: "%.1fk", n / 1_000) }
    return String(format: "%.0f", n)
}

/// Cost with a hard distinction between "not observed" and "known zero":
/// nil → "—", 0 → "$0.00".
func compactCost(_ n: Double?) -> String {
    guard let n = n else { return "—" }
    if n == 0 { return "$0.00" }
    if n < 0.01 { return String(format: "$%.4f", n) }
    return String(format: "$%.2f", n)
}

/// Exact localized count for hover help / accessibility, e.g. "3,234,511 tokens".
/// Integer-only: no Double overload exists. The NumberFormatter-based Double
/// path was removed because it rounds at ≥2^54 — all integral counts must
/// go through the Int overload below.

/// Plain localized token count without "tokens" suffix, for inline component lists.
///
/// Integer-exact: formats `NSNumber(value: Int)`. NumberFormatter's decimal
/// conversion of a Double-valued NSNumber rounds at ≥2^54 (its shortest
/// round-trip decimal for 2^55 is ...970 while the Double itself is exact),
/// so every integral count must go through this Int path. Proven by the
/// boundary tests in Tests/I2ContractTests.swift.
func tokenCountString(_ n: Int) -> String {
    // Manual grouping over String(n): NumberFormatter converts integer
    // NSNumbers through a double internally and rounds ODD values above
    // 2^53 (e.g. 9,007,199,254,740,993 -> ...992), so it cannot be used
    // for an exact integral display at any magnitude. Pinned by the
    // boundary tests in Tests/I2ContractTests.swift.
    //
    // Negative handling: the grouping loop counts '-' as a character, so
    // negatives with digit-count ≡ 0 (mod 3) get a spurious comma after
    // the sign (-123 → "-,123"). No model path produces negative counts,
    // but the function is ours and must be correct at every input.
    // Textual sign approach: drop the sign, group the magnitude, prepend.
    // Never negates n — negation traps on Int.min (overflow). Caught by
    // @turing/@codie at 0550703; this form avoids the trap they identified.
    let negative = n < 0
    let digits = negative ? String(String(n).dropFirst()) : String(n)
    var grouped = ""
    var inserted = 0
    for ch in digits.reversed() {
        if inserted > 0 && inserted % 3 == 0 {
            grouped.append(",")
        }
        grouped.append(ch)
        inserted += 1
    }
    let result = String(grouped.reversed())
    return negative ? "-" + result : result
}

/// Integer-exact "N tokens" string (hover helps, AX labels).
func exactTokens(_ n: Int) -> String {
    "\(tokenCountString(n)) tokens"
}

let dayParser: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
}()

let weekdayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "E"
    return f
}()

let relativeAgeFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .short
    return f
}()

/// Mirror of the collector's clean_provider() — strips whitespace, truncates
/// to 32 characters, defaults to 'local'. Used to normalize detail-dictionary
/// keys so they match the providerUsage keys (R3 key-space mismatch).
func cleanProvider(_ s: String) -> String {
    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
    let truncated = String(trimmed.prefix(32))
    return truncated.isEmpty ? "local" : truncated
}

/// Compute the day-age label for a record timestamp.
/// Returns "today", "yesterday", "N days old", or "age unknown".
/// Uses startOfDay normalization to count calendar days, not elapsed 24-hour periods.
func dayAgeLabel(updatedAt: Date?, now: Date = Date()) -> String {
    guard let t = updatedAt else {
        return "age unknown"
    }
    let cal = Calendar.current
    let startT = cal.startOfDay(for: t)
    let startNow = cal.startOfDay(for: now)
    let days = cal.dateComponents([.day], from: startT, to: startNow).day ?? 0
    return days == 0 ? "today" : days == 1 ? "yesterday" : "\(days) days old"
}

// MARK: - R4: Snapshot date helpers for receipt

/// R4: Parse ISO 8601 date string to Date
func parseISODate(_ s: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: s) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: s)
}

/// R4: Format snapshot date as "today", "yesterday", or YYYY-MM-DD
func formatSnapshotDay(_ date: Date) -> String {
    let cal = Calendar.current
    if cal.isDateInToday(date) {
        return "today"
    } else if cal.isDateInYesterday(date) {
        return "yesterday"
    } else {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

// MARK: - B4: Aggregate reasoning helper

/// B4: Returns the aggregate reasoning token count when > 0, else nil.
/// Used to decide whether to show the "Total reasoning" chip in the totals
/// section. Never attributed to any specific model — it is a record-level
/// aggregate only.
func aggregateReasoning(_ rec: UsageRecord) -> Int? {
    guard let r = rec.details?.totals?.reasoning, r > 0 else { return nil }
    return r
}

// MARK: - B6: Account quota helpers

/// B6: TTL for account quota observations (seconds). Collector validates
/// fetchedAt <= now < expiresAt <= fetchedAt + TTL, so this matches the
/// collector's window. The UI uses this to expire observations independently
/// while the menu is open.
let accountQuotaTTL: TimeInterval = 600

/// B6: Check if a snapshot is still fresh (within its TTL window).
/// Uses the snapshot's own expiresAt, not a re-fetch — refresh must not
/// extend observations or imply a provider fetch.
func isSnapshotFresh(_ snap: AccountSnapshot, now: Date = Date()) -> Bool {
    let nowEpoch = now.timeIntervalSince1970
    return nowEpoch < snap.expiresAt
}

/// B6: Format the remaining time until a snapshot expires.
/// Returns "fresh" if >5 min, "Nm" if <5 min, or "expired" if past TTL.
func snapshotFreshness(_ snap: AccountSnapshot, now: Date = Date()) -> String {
    let nowEpoch = now.timeIntervalSince1970
    let remaining = snap.expiresAt - nowEpoch
    if remaining <= 0 { return "expired" }
    if remaining < 300 {  // <5 min
        let mins = Int(remaining / 60)
        return mins == 0 ? "<1m" : "\(mins)m"
    }
    return "fresh"
}

/// B6: Format a reset time as a relative label.
/// Returns "in Nm", "in Nh", "reset passed" if past resetAt, or
/// "Reset time unavailable" if resetAt is nil.
///
/// Nil meaning (per quota_io.py): `if reset is None or reset > now: clean.append(...)`
/// retains windows with `reset is None` as valid observations. Nil therefore means
/// *timing data is missing*, not that no reset is scheduled. We render an explicit
/// "unavailable" label rather than an em dash that could imply certainty.
func formatResetTime(_ resetAt: Double?, now: Date = Date()) -> String {
    guard let resetAt = resetAt else { return "Reset time unavailable" }
    let nowEpoch = now.timeIntervalSince1970
    let remaining = resetAt - nowEpoch
    if remaining <= 0 { return "reset passed" }
    if remaining < 3600 {
        let mins = Int(remaining / 60)
        return mins == 0 ? "<1m" : "in \(mins)m"
    }
    if remaining < 86400 {
        let hours = Int(remaining / 3600)
        return "in \(hours)h"
    }
    let days = Int(remaining / 86400)
    return "in \(days)d"
}

/// B6: True when a window's resetAt has passed (reset is non-nil and <= now).
/// The producer drops `reset <= now` windows at collection time, but the UI holds
/// its own decoded copy — a window valid at collection can cross resetAt while the
/// popover stays open. Callers must not present the old remaining% as current when
/// this returns true.
func isWindowResetPassed(_ window: AccountWindow, now: Date = Date()) -> Bool {
    guard let resetAt = window.resetAt else { return false }
    return now.timeIntervalSince1970 >= resetAt
}

/// B6: Compose the per-window accessibility announcement for a quota window.
/// Second consumer of formatPercent/formatResetTime alongside the visual row;
/// extracted from accountAccessibilityLabel so the "no stale percentage in the
/// AX announcement" rule is enforced by tests (t_d5fa34be).
///
/// Branch order mirrors the visual path: a window whose resetAt crossed while
/// the popover was open must never announce its old remaining%. Strings are
/// byte-identical to the inline versions they replace.
func accountWindowAnnouncement(_ window: AccountWindow, now: Date = Date()) -> String {
    if isWindowResetPassed(window, now: now) {
        // Reset passed without recollection — don't announce stale allowance
        return "\(window.label) reset passed, awaiting re-observation"
    } else if window.resetAt == nil {
        // Timing data missing — separate phrasing from the visual label
        return "\(window.label) \(formatPercent(window.remainingPercent)) remaining, reset time unavailable"
    } else {
        return "\(window.label) \(formatPercent(window.remainingPercent)) remaining, resets \(formatResetTime(window.resetAt, now: now))"
    }
}

/// B6: Format a percentage as "N%" with one decimal if needed.
func formatPercent(_ p: Double) -> String {
    if p == floor(p) {
        return "\(Int(p))%"
    }
    return String(format: "%.1f%%", p)
}

/// B6: Display label for a provider in the accounts section.
/// Reuses the same mapping as providersSection for consistency.
func accountProviderLabel(_ p: String) -> String {
    switch p {
    case "openai-codex": return "Codex"
    case "anthropic": return "Anthropic"
    case "nous": return "Nous"
    case "openrouter": return "OpenRouter"
    default: return p
    }
}

/// B6: Format the access status for display.
/// Only nous records carry denied/member-cap-exceeded inside the 600s window.
/// Other providers always show "unknown" or "allowed" — represent that
/// asymmetry faithfully rather than generalizing.
func formatAccessStatus(_ status: String, provider: String) -> String {
    switch status {
    case "denied": return "Access denied"
    case "member-cap-exceeded": return "Member cap exceeded"
    case "allowed": return "Allowed"
    case "unknown": return "—"
    default: return "—"
    }
}

/// B6: Check if a snapshot has an access restriction (denied or member-cap-exceeded).
/// Only meaningful for nous provider per quota_io.py.
func hasAccessRestriction(_ snap: AccountSnapshot) -> Bool {
    return snap.accessStatus == "denied" || snap.accessStatus == "member-cap-exceeded"
}

// MARK: - F5: Provider cost helpers

/// F5: True when any provider row has a nil cost (so the legend should show
/// even when the aggregate is known).
func hasNilProviderCost(_ rec: UsageRecord) -> Bool {
    guard let providerUsage = rec.providerUsage else { return false }
    return providerUsage.keys.contains { name in
        resolveProviderCost(rec: rec, providerName: name, legacyCost: providerUsage[name]?.estimatedCostUsd) == nil
    }
}

// MARK: - B2: Workload helpers (free functions for testability)

/// B2: Priority for task sorting (lower = appears first).
/// Collector-generated labels (ordinary, unknown, other) should appear last.
func taskSortPriority(_ name: String) -> Int {
    switch name {
    case "other": return 100
    case "unknown": return 90
    case "ordinary": return 80
    default: return 0
    }
}

/// B2: Format task label for display.
/// Collector-generated labels get neutral treatment; explicit task strings pass through.
func taskLabel(_ name: String) -> String {
    switch name {
    case "ordinary": return "Ordinary"
    case "unknown": return "Unknown"
    case "other": return "Other"
    default: return name
    }
}

// MARK: - B3: Accounting evidence helpers (free functions for testability)

/// B3: Format recorded cost with status context.
/// Shows the value and clarifies it's a database observation, not invoice reconciliation.
func formatRecordedCost(_ n: Double?) -> String {
    guard let n = n else { return "Recorded cost unavailable" }
    return "Recorded \(compactCost(n)); this is a database observation, not invoice reconciliation"
}

/// B3: Format row-status breakdown for accounting evidence.
/// Returns a human-readable summary of how many rows have each cost status.
func formatRowStatusBreakdown(_ statusRows: [String: Int]?) -> String? {
    guard let rows = statusRows, !rows.isEmpty else { return nil }

    var parts: [String] = []
    if let estimated = rows["estimated"], estimated > 0 {
        parts.append("\(estimated) with estimated cost")
    }
    if let actual = rows["actual"], actual > 0 {
        parts.append("\(actual) with actual cost")
    }
    if let included = rows["included"], included > 0 {
        parts.append("\(included) subscription-included")
    }
    if let unknown = rows["unknown"], unknown > 0 {
        parts.append("\(unknown) with unknown cost status")
    }

    return parts.isEmpty ? nil : parts.joined(separator: ", ")
}

/// B3: Format call-availability evidence.
/// Distinguishes between total calls and rows with missing call counts.
func formatCallAvailability(calls: Int?, unknownCallRows: Int?) -> String {
    let callsText: String
    if let calls = calls {
        callsText = "\(calls) reported calls"
    } else {
        callsText = "Calls unavailable"
    }

    guard let unknown = unknownCallRows, unknown > 0 else {
        return callsText
    }

    let plural = unknown == 1 ? "row" : "rows"
    return "\(callsText); call count unavailable for \(unknown) usage \(plural)"
}

// MARK: - B5: Usage receipt formatter

/// B5: Format a plain-text usage receipt for clipboard copy.
/// Includes: snapshot timestamp, intended scope, coverage qualification,
/// today's estimate, recorded-history totals, unknown values, data-source explanation.
/// Excludes: file paths, profile/account identifiers, task labels, raw stderr, session content.
/// The freshness timestamp is the SNAPSHOT time (updatedAt), never the copy time.
func formatUsageReceipt(_ rec: UsageRecord, loadState: UsageModel.LoadState) -> String {
    var lines: [String] = []

    // Header
    lines.append("Hermes Usage Summary")
    lines.append("")

    // Snapshot timestamp (from collector, not copy time)
    if let updatedAt = rec.updatedAt {
        lines.append("Collected: \(updatedAt)")
    } else {
        lines.append("Collected: timestamp unavailable")
    }

    // Intended scope (from details or root)
    let scope = rec.details?.scope ?? "device"
    let coverage = rec.details?.coverage ?? "bounded local history"
    lines.append("Scope: \(scope) (intended, not proven complete)")
    lines.append("Coverage: \(coverage)")

    // Collection state
    switch loadState {
    case .success:
        if rec.details?.truncated == true {
            lines.append("Status: partial collection (some data may be missing)")
        } else {
            lines.append("Status: complete collection")
        }
    case .noData:
        lines.append("Status: no local data found")
    case .noStores:
        lines.append("Status: no session stores found")
    case .unreadable:
        lines.append("Status: stores exist but could not be read")
    case .unrecognized:
        lines.append("Status: data format not recognized")
    case .failed:
        lines.append("Status: collection failed")
    case .stale:
        lines.append("Status: showing previous data (refresh failed)")
    case .initial, .loading:
        lines.append("Status: not yet collected")
    }

    lines.append("")

    // R4: Daily estimate qualified by snapshot date, not copy-time "Today"
    let snapshotDayLabel = rec.updatedAt.flatMap { parseISODate($0) }.map { formatSnapshotDay($0) } ?? "snapshot day"
    if let todayTokens = rec.todayTotalTokens {
        lines.append("Daily estimate (\(snapshotDayLabel)): \(exactTokens(todayTokens)) (estimated)")
    } else {
        lines.append("Daily estimate (\(snapshotDayLabel)): unavailable")
    }

    // Recorded history totals
    if let totals = rec.details?.totals {
        if let tokens = totals.tokens {
            lines.append("Recorded history: \(exactTokens(tokens))")
        } else {
            lines.append("Recorded history: unavailable")
        }

        if let calls = totals.calls {
            let unknownText = totals.unknownCallRows.map { " (call count unavailable for \($0) rows)" } ?? ""
            lines.append("Reported calls: \(calls)\(unknownText)")
        } else {
            lines.append("Reported calls: unavailable")
        }

        if let estUsd = totals.estimatedUsd {
            lines.append("Estimated cost: \(compactCost(estUsd)) (not invoice reconciliation)")
        } else {
            lines.append("Estimated cost: unavailable")
        }

        if let actualUsd = totals.actualUsd {
            lines.append("Actual cost: \(compactCost(actualUsd)) (database observation)")
        }
    } else {
        lines.append("Recorded history: unavailable")
        lines.append("Reported calls: unavailable")
        lines.append("Estimated cost: unavailable")
    }

    lines.append("")

    // Provider summary (aggregate only, no identifiers)
    if let providers = rec.providerUsage, !providers.isEmpty {
        let count = providers.count
        let plural = count == 1 ? "provider" : "providers"
        lines.append("Providers: \(count) \(plural)")
    }

    // Model summary (aggregate only)
    if let models = rec.modelUsage, !models.isEmpty {
        let count = models.count
        let plural = count == 1 ? "model" : "models"
        lines.append("Models: \(count) \(plural)")
    }

    lines.append("")

    // Data source explanation
    if let attribution = rec.details?.dailyAttribution {
        lines.append("Daily attribution: \(attribution)")
    }
    lines.append("Source: local Hermes Agent session stores on this Mac")
    lines.append("")
    lines.append("This is bounded local history, not a complete inventory.")
    lines.append("Costs are database observations, not billing statements.")

    return lines.joined(separator: "\n")
}

/// F3: Format explicit accessibility summary for a workload row.
/// Names unavailable values rather than relying on punctuation or inherited help.
func formatWorkloadAccessibilitySummary(_ task: (name: String, tokens: Int?, calls: Int?, estimatedUsd: Double?)) -> String {
    var parts: [String] = [taskLabel(task.name)]
    
    if let calls = task.calls {
        parts.append("\(calls) calls")
    } else {
        parts.append("Calls not recorded")
    }
    
    if let tokens = task.tokens {
        parts.append("\(compactTokens(Double(tokens))) tokens")
    } else {
        parts.append("Tokens not recorded")
    }
    
    if let usd = task.estimatedUsd {
        parts.append("Cost \(compactCost(usd))")
    } else {
        parts.append("Cost unavailable; not zero")
    }
    
    return parts.joined(separator: ", ")
}

/// F5: Check if any workload row has a nil estimated cost.
func hasNilWorkloadCost(_ rec: UsageRecord) -> Bool {
    guard let tasks = rec.details?.tasks else { return false }
    return tasks.values.contains { $0.estimatedUsd == nil }
}

/// F6: Format call-coverage warning for the summary.
/// Uses the same phrasing as formatCallAvailability for consistency.
func formatCallCoverageWarning(unknownCallRows: Int) -> String {
    let plural = unknownCallRows == 1 ? "row" : "rows"
    return "Call count unavailable for \(unknownCallRows) usage \(plural)"
}

/// Resolve the display cost for a provider row (R3).
/// When detail data exists: normalize its keys to match providerUsage keys,
/// then look up. A miss with details present means cost was never observed → nil.
/// When detail data is absent entirely: fall back to legacy providerUsage field
/// (the only source available in old collector payloads).
func resolveProviderCost(rec: UsageRecord, providerName: String, legacyCost: Double?) -> Double? {
    guard let providers = rec.details?.providers else {
        // No detail data at all — legacy field is the only source.
        return legacyCost
    }
    // Normalize detail keys to match providerUsage keys.
    // If two raw keys normalize to the same value, merge conservatively:
    // any disagreement or any nil → treat as unknown (nil). This preserves
    // R3's honesty principle: a merged provider must not claim a known cost
    // it did not observe across all its raw variants.
    let normalized: [String: ProviderDetail] = Dictionary(
        providers.map { (cleanProvider($0.key), $0.value) },
        uniquingKeysWith: { a, b in
            // Conservative merge: if either has nil cost, or they disagree, → unknown.
            // Note: exact float comparison means near-identical float noise reads as unknown;
            // this is intentional — ambiguous cost data should display as unknown, not guessed.
            guard let costA = a.estimatedUsd, let costB = b.estimatedUsd, costA == costB else {
                // Return a detail with nil cost to signal unknown.
                return ProviderDetail(
                    rows: nil, calls: nil, unknownCallRows: nil,
                    tokens: nil, reasoning: nil, cacheRead: nil,
                    estimatedUsd: nil, actualUsd: nil, latestStatusRows: nil
                )
            }
            // Both agree on a known cost — keep the first (they're identical for cost).
            return a
        }
    )
    // Detail data exists: a miss means cost was never observed → nil (em-dash).
    // Do NOT fall back to legacy zero — that would mask an unobserved cost.
    return normalized[providerName]?.estimatedUsd
}

// MARK: - Collector runner

struct CollectorError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Result of one collector run, decoupled from how it was executed so
/// lifecycle tests can drive synthetic outcomes (R1/I2).
struct CollectorOutcome {
    enum Kind: Equatable {
        case success(Data)
        case failure(String)
        /// A3: collector exited 1 with the known "no Hermes Agent session store found"
        /// diagnostic. Distinct from generic failure so the UI can render a friendly
        /// empty state instead of a generic error.
        case noStores(String)
    }
    let kind: Kind
    /// Wall-clock seconds the child ran (or was allowed to run) — surfaced
    /// for tests and diagnostics.
    let elapsed: TimeInterval
}

/// Clock abstraction so deadline logic is testable without real sleeps (I2).
protocol DeadlineClock {
    func now() -> Date
}

struct SystemDeadlineClock: DeadlineClock {
    func now() -> Date { Date() }
}

/// How the collector subprocess is spawned. Production uses /usr/bin/python3;
/// tests substitute synthetic scripts (R1/I2).
protocol CollectorExecuting {
    /// Run the collector with the given timeout and output byte caps.
    /// Returns a completed outcome — never blocks past `timeout`.
    func run(timeout: TimeInterval, maxOutputBytes: Int, maxErrorBytes: Int) -> CollectorOutcome
}

enum CollectorRunner {
    /// Pipe capacity on macOS is 64 KiB (typically 16 KiB–64 KiB). The
    /// collector's payload ceiling is 256 KiB — 4x the pipe buffer — so
    /// waitUntilExit-before-read can deadlock (R1). Reading concurrently
    /// while the child runs removes the dependency on pipe capacity.
    static let defaultTimeout: TimeInterval = 30
    /// Matches the collector's MAX_RECORD_BYTES (256 KiB); anything larger
    /// means the child misbehaved.
    static let maxOutputBytes = 512 * 1024
    /// Matches CappedStderr's budget with headroom for the wrap message.
    static let maxErrorBytes = 32 * 1024

    static func trim(_ s: String, to limit: Int) -> String {
        String(s.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Shared outcome classification used by the real executor and tests.
    static func classify(exitStatus: Int32,
                          timedOut: Bool,
                          outputTruncated: Bool,
                          data: Data,
                          stderrText: String,
                          elapsed: TimeInterval) -> CollectorOutcome {
        if timedOut {
            return CollectorOutcome(kind: .failure(
                "Collector timed out after \(Int(elapsed.rounded()))s and was terminated"),
                elapsed: elapsed)
        }
        if exitStatus != 0 {
            let err = trim(stderrText, to: 300)
            // A3: recognize the known no-store diagnostic so the UI can render
            // a friendly empty state instead of a generic error.
            if err.contains("no Hermes Agent session store found") {
                return CollectorOutcome(kind: .noStores(err), elapsed: elapsed)
            }
            return CollectorOutcome(kind: .failure(
                "Collector exit \(exitStatus)\(err.isEmpty ? "" : ": \(err)")"),
                elapsed: elapsed)
        }
        if data.isEmpty {
            let err = trim(stderrText, to: 300)
            return CollectorOutcome(kind: .failure(
                "Collector produced no output\(err.isEmpty ? "" : " (stderr: \(err))")"),
                elapsed: elapsed)
        }
        if outputTruncated {
            return CollectorOutcome(kind: .failure(
                "Collector output exceeded \(maxOutputBytes) bytes — refusing to parse a truncated payload"),
                elapsed: elapsed)
        }
        return CollectorOutcome(kind: .success(data), elapsed: elapsed)
    }
}

/// Real subprocess executor: drains stdout AND stderr on dedicated threads
/// while the child runs, enforces a wall-clock deadline, and terminates
/// (SIGTERM → SIGKILL) an overdue child before reaping it. Cannot deadlock
/// on pipe backpressure (R1).
struct PythonCollectorExecutor: CollectorExecuting {
    let scriptPath: String

    func run(timeout: TimeInterval,
             maxOutputBytes: Int,
             maxErrorBytes: Int) -> CollectorOutcome {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        task.arguments = ["-B", scriptPath, "--force"]
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe

        do {
            try task.run()
        } catch {
            return CollectorOutcome(
                kind: .failure("Failed to start python3: \(error.localizedDescription)"),
                elapsed: 0)
        }

        // Drain both pipes on background threads while the child runs.
        // Each pipe gets its own thread — this is what breaks the
        // wait-before-read deadlock: the child can always make write progress.
        let outReader = PipeReader(handle: outPipe.fileHandleForReading, cap: maxOutputBytes)
        let errReader = PipeReader(handle: errPipe.fileHandleForReading, cap: maxErrorBytes)
        let outThread = JoinableThread(name: "collector-stdout") { outReader.drain() }
        let errThread = JoinableThread(name: "collector-stderr") { errReader.drain() }
        outThread.start()
        errThread.start()

        let start = Date()
        var timedOut = false
        // Poll with a deadline instead of an unbounded waitUntilExit.
        while task.isRunning {
            if Date().timeIntervalSince(start) >= timeout {
                timedOut = true
                break
            }
            task.waitUntilExit(withTimeout: 0.05)
        }
        let elapsed = Date().timeIntervalSince(start)

        if timedOut {
            task.terminate() // SIGTERM first, gentle shutdown
            // Give it a moment to exit on SIGTERM, then SIGKILL.
            let killDeadline = Date().addingTimeInterval(2.0)
            while task.isRunning && Date() < killDeadline {
                task.waitUntilExit(withTimeout: 0.05)
            }
            if task.isRunning {
                let force = Process()
                force.executableURL = URL(fileURLWithPath: "/usr/bin/kill")
                force.arguments = ["-9", "\(task.processIdentifier)"]
                try? force.run()
                // Reap: block until the kernel releases the child.
                task.waitUntilExit()
            }
            // Closing our read ends unblocks the drain threads (they see EOF
            // or EPIPE) so they finish even if the child never flushes.
            try? outPipe.fileHandleForReading.close()
            try? errPipe.fileHandleForReading.close()
            outThread.join()
            errThread.join()
            return CollectorOutcome(kind: .failure(
                "Collector timed out after \(Int(elapsed.rounded()))s and was terminated"),
                elapsed: elapsed)
        }

        // Normal exit: pipes hit EOF on their own; wait for the readers.
        outThread.join()
        errThread.join()

        return CollectorRunner.classify(
            exitStatus: task.terminationStatus,
            timedOut: false,
            outputTruncated: outReader.truncated,
            data: outReader.data,
            stderrText: String(data: errReader.data, encoding: .utf8) ?? "",
            elapsed: elapsed)
    }
}

/// Minimal joinable thread wrapper — Foundation's Thread gained no join()
/// API at our deployment target (macOS 13), so block on a semaphore the
/// body signals when it finishes.
final class JoinableThread {
    private let body: () -> Void
    private let done = DispatchSemaphore(value: 0)
    private let name: String

    init(name: String, body: @escaping () -> Void) {
        self.name = name
        self.body = body
    }

    func start() {
        let t = Thread { [body, done] in
            body()
            done.signal()
        }
        t.name = name
        t.start()
    }

    func join() {
        _ = done.wait(timeout: .now() + 10)
    }
}

/// Reads a file handle up to `cap` bytes, recording truncation. Thread-safe
/// enough for its single-drain-thread use: only the owning thread touches
/// `data`/`truncated` until `drain()` returns.
private final class PipeReader {
    let handle: FileHandle
    let cap: Int
    private(set) var data = Data()
    private(set) var truncated = false

    init(handle: FileHandle, cap: Int) {
        self.handle = handle
        self.cap = cap
    }

    func drain() {
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break } // EOF
            if data.count + chunk.count > cap {
                let room = max(0, cap - data.count)
                if room > 0 { data.append(chunk.prefix(room)) }
                truncated = true
                // Keep draining without storing so the child never blocks on
                // us — we must consume the stream to EOF for it to exit.
                continue
            }
            data.append(chunk)
        }
    }
}

extension Process {
    /// Waits for exit for at most `seconds`; returns without throwing.
    func waitUntilExit(withTimeout seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while isRunning && Date() < deadline {
            usleep(10_000) // 10 ms
        }
    }
}


@MainActor
final class UsageModel: ObservableObject {
    /// Distinct lifecycle states (R6). Separate "never loaded" from "failed
    /// with no prior record" so the menu bar can warn, and from "no data"
    /// so an empty install can show a deliberate empty state.
    /// A3: added noStores (no session stores found) and unreadable (stores
    /// exist but couldn't be read) to distinguish from generic failure.
    /// A6: added unrecognized (valid JSON but not a valid usage record).
    enum LoadState: Equatable {
        case initial
        case loading
        case success
        case noData        // collector said hasLocalStats=false (genuine emptiness)
        case noStores(String)  // A3: no session stores found at all
        case unreadable(String)  // A3: stores exist but couldn't be read (truncated+hasLocalStats=false)
        case unrecognized(String)  // A6: valid JSON but not a valid usage record
        case failed(String)  // error with no prior record
        case stale(String)   // error but prior record retained
    }

    @Published var record: UsageRecord?
    @Published var errorText: String?
    @Published var updatedAt: Date?
    @Published var isLoading = false
    @Published var loadState: LoadState = .initial
    /// True when the last refresh failed but we still show a previous record.
    @Published var isStale = false
    /// R7: lightweight display clock for time-dependent UI (day-rollover,
    /// relative-age). Bumped every 60s and on wake; does NOT trigger
    /// collection. Views observing this re-render on clock boundaries.
    @Published var displayTick = 0

    private var startedOnce = false
    /// Executor injected for tests; production resolves from the bundle path
    /// (R1/I2 — lifecycle tests drive synthetic collectors through this).
    private let executor: CollectorExecuting
    private let collectorTimeout: TimeInterval

    init(executor: CollectorExecuting? = nil,
         collectorTimeout: TimeInterval = CollectorRunner.defaultTimeout) {
        self.executor = executor ?? PythonCollectorExecutor(
            scriptPath: Bundle.main.resourceURL!
                .appendingPathComponent("collector/hermes-usage.py").path)
        self.collectorTimeout = collectorTimeout
        // Kick off collection immediately at launch, not on first popover open.
        startIfNeeded()
        // R7: start lightweight display clock (60s interval, no collection).
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.displayTick += 1 }
        }
    }

    func startIfNeeded() {
        guard !startedOnce else { return }
        startedOnce = true
        start()
    }

    private let refreshInterval: TimeInterval = 900 // 15 min, matches Omarchy default

    func start() {
        refresh()
        Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// Refresh on popover open only when the data is stale (failed last time,
    /// older than the auto interval, or from a previous day) (R6: also retry
    /// initial failures).
    func refreshIfStale() {
        guard !isLoading else { return }
        // Retry initial failures and error states
        if case .initial = loadState { refresh(); return }
        if case .failed = loadState { refresh(); return }
        // A3/A6: retry noStores, unreadable, unrecognized
        if case .noStores = loadState { refresh(); return }
        if case .unreadable = loadState { refresh(); return }
        if case .unrecognized = loadState { refresh(); return }
        if isStale || isDayStale { refresh(); return }
        if let t = updatedAt, Date().timeIntervalSince(t) >= refreshInterval { refresh() }
    }

    /// True when the retained record was collected on a previous calendar day,
    /// so "today" numbers must not silently be yesterday's.
    var isDayStale: Bool {
        guard let t = updatedAt else { return false }
        return !Calendar.current.isDateInToday(t)
    }

    var menuBarWarning: Bool {
        // R6: warn on failure regardless of prior record
        if isStale { return true }
        if isDayStale { return true }
        if case .failed = loadState { return true }
        // A3/A6: warn on error states
        if case .noStores = loadState { return true }
        if case .unreadable = loadState { return true }
        if case .unrecognized = loadState { return true }
        return false
    }

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        errorText = nil
        loadState = .loading
        let executor = executor
        let timeout = collectorTimeout
        Task.detached(priority: .utility) {
            // R1: bounded capture + deadline; the executor always returns.
            let outcome = executor.run(
                timeout: timeout,
                maxOutputBytes: CollectorRunner.maxOutputBytes,
                maxErrorBytes: CollectorRunner.maxErrorBytes)
            await MainActor.run {
                self.isLoading = false
                switch outcome.kind {
                case .success(let data):
                    let decoder = JSONDecoder()
                    if let rec = try? decoder.decode(UsageRecord.self, from: data) {
                        // A6: validate minimum record contract before accepting as fresh
                        if !self.isValidRecord(rec) {
                            let msg = "Usage format not recognized"
                            self.isStale = (self.record != nil)
                            self.errorText = msg
                            self.loadState = self.record != nil ? .stale(msg) : .unrecognized(msg)
                            return
                        }
                        // R6 + A3: distinguish states
                        if rec.hasLocalStats == false {
                            // A3: hasLocalStats=false + truncated=true means stores exist but
                            // couldn't be read, not genuine emptiness. If we have a prior
                            // valid record, retain it as stale; otherwise show unreadable.
                            // F2: never store an unreadable envelope as a record — it is an
                            // error, not data. Repeated unreadable results must stay
                            // .unreadable, not become false "saved results".
                            if rec.details?.truncated == true {
                                let msg = "Couldn't read local usage"
                                if self.record != nil {
                                    self.isStale = true
                                    self.loadState = .stale(msg)
                                    self.errorText = msg
                                } else {
                                    self.loadState = .unreadable(msg)
                                    self.isStale = false
                                    self.errorText = msg
                                    // F2: do NOT set record or updatedAt — an unreadable
                                    // envelope is not valid usage data
                                }
                            } else {
                                self.loadState = .noData
                                self.record = rec
                                self.updatedAt = Date()
                                self.isStale = false
                                self.errorText = nil
                            }
                        } else {
                            self.loadState = .success
                            self.record = rec
                            self.updatedAt = Date()
                            self.isStale = false
                            self.errorText = nil
                        }
                    } else {
                        self.isStale = (self.record != nil)
                        self.errorText = "Could not parse collector output"
                        self.loadState = self.record != nil ? .stale("Could not parse collector output") : .failed("Could not parse collector output")
                    }
                case .noStores(let diagnostic):
                    // A3: no stores found — distinct from generic failure
                    self.isStale = (self.record != nil)
                    self.errorText = diagnostic
                    self.loadState = self.record != nil ? .stale(diagnostic) : .noStores(diagnostic)
                case .failure(let message):
                    self.isStale = (self.record != nil)
                    self.errorText = message
                    self.loadState = self.record != nil ? .stale(message) : .failed(message)
                }
            }
        }
    }

    /// A6: validate the minimum supported record contract before accepting a
    /// result as fresh. The bundled producer always emits id="hermes",
    /// name="Hermes Agent", schemaVersion=1, hasLocalStats and bounded-history
    /// metadata (collector hermes-usage.py:52-53, 601-610, 644-659). A record
    /// that does not match this identity is not from a compatible producer —
    /// reject it and retain any previous valid record as stale.
    private func isValidRecord(_ rec: UsageRecord) -> Bool {
        // Producer identity: the bundled collector always emits these exact
        // values (hermes-usage.py:52-53, 601-604). A record with a different
        // id/name or missing schemaVersion is not from Hermes.
        guard rec.id == "hermes" else { return false }
        guard rec.name == "Hermes Agent" else { return false }
        guard rec.schemaVersion == 1 else { return false }
        // hasLocalStats distinguishes "no data yet" (false) from "has data"
        // (true). An object without it cannot be classified.
        guard rec.hasLocalStats != nil else { return false }
        return true
    }
}

// MARK: - Weekly bar chart

struct WeekBars: View {
    let days: [RecentDay]
    let palettePrimary: Color
    let paletteSecondary: Color

    private var maxTokens: Double {
        max(Double(days.map { $0.messageCount }.max() ?? 0), 1)
    }

    private var todayString: String {
        dayParser.string(from: Date())
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                VStack(spacing: 3) {
                    Text(compactTokens(Double(day.messageCount)))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(paletteSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .accessibilityHidden(true)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(fillColor(day))
                        .frame(height: barHeight(day))
                        .accessibilityHidden(true)
                    Text(dayLabel(day.date))
                        .font(.caption.weight(isToday(day.date) ? .bold : .regular))
                        .foregroundStyle(isToday(day.date) ? palettePrimary : paletteSecondary)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity)
                .help(barHelp(day))
                .accessibilityElement()
                .accessibilityLabel(barHelp(day))
            }
        }
    }

    private func isToday(_ dateStr: String) -> Bool {
        dateStr == todayString
    }

    /// Zero days get a 2pt baseline tick so "zero" reads differently from "no bar".
    private func barHeight(_ day: RecentDay) -> CGFloat {
        day.messageCount > 0 ? max(3, 44 * Double(day.messageCount) / maxTokens) : 2
    }

    private func fillColor(_ day: RecentDay) -> Color {
        if isToday(day.date) { return Color.accentColor }
        return day.messageCount > 0 ? Color.secondary.opacity(0.45) : Color.secondary.opacity(0.15)
    }

    private func dayLabel(_ dateStr: String) -> String {
        if isToday(dateStr) { return "Today" }
        guard let d = dayParser.date(from: dateStr) else { return "" }
        return weekdayFormatter.string(from: d)
    }

    private func barHelp(_ day: RecentDay) -> String {
        "\(day.date) · \(exactTokens(day.messageCount))"
    }
}

// MARK: - Content view

struct ContentView: View {
    @EnvironmentObject var model: UsageModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var showAllModels = false
    @State private var clipboardCopied = false
    @State private var clipboardError: String?
    @State private var feedbackTimer: DispatchWorkItem?

    // MARK: - Opaque appearance-specific background (t_dba69d81)
    // Pinned palette: opaque backgrounds remove wallpaper dependence.
    // Light: #F2F2F2, Dark: #1E1E1E
    private var panelBackground: Color {
        colorScheme == .dark ? Color(red: 0x1E/255, green: 0x1E/255, blue: 0x1E/255)
                              : Color(red: 0xF2/255, green: 0xF2/255, blue: 0xF2/255)
    }

    // MARK: - Pinned neutral palette (t_dba69d81)
    // Primary: light #1D1D1F (15.034:1), dark #FFFFFF (16.671:1)
    private var palettePrimary: Color {
        colorScheme == .dark ? Color(red: 1.0, green: 1.0, blue: 1.0)
                              : Color(red: 0x1D/255, green: 0x1D/255, blue: 0x1F/255)
    }
    // Secondary: light #5A5A60 (6.118:1), dark #C7C7CC (9.899:1)
    private var paletteSecondary: Color {
        colorScheme == .dark ? Color(red: 0xC7/255, green: 0xC7/255, blue: 0xCC/255)
                              : Color(red: 0x5A/255, green: 0x5A/255, blue: 0x60/255)
    }
    // Tertiary: light #6E6E73 (4.530:1), dark #B0B0B8 (7.739:1 dimmer alt)
    private var paletteTertiary: Color {
        colorScheme == .dark ? Color(red: 0xB0/255, green: 0xB0/255, blue: 0xB8/255)
                              : Color(red: 0x6E/255, green: 0x6E/255, blue: 0x73/255)
    }

    // MARK: - Pinned accent palette (t_dba69d81)
    // Accents are per-appearance. Never share hex across appearances.
    // Orange: light #B25E00 (graphic only, 3:1 ✓), dark #FF9F0A (8.110:1)
    private var paletteAccentOrange: Color {
        colorScheme == .dark ? Color(red: 0xFF/255, green: 0x9F/255, blue: 0x0A/255)
                              : Color(red: 0xB2/255, green: 0x5E/255, blue: 0x00/255)
    }
    // Green: light #0A6B2E (5.945:1), dark #30D158 (8.246:1)
    private var paletteAccentGreen: Color {
        colorScheme == .dark ? Color(red: 0x30/255, green: 0xD1/255, blue: 0x58/255)
                              : Color(red: 0x0A/255, green: 0x6B/255, blue: 0x2E/255)
    }

    // MARK: - Contrast-scoped status glyphs (t_98d271e9, revised t_40db1924)
    // Two colour systems coexist by design (t_9b863783):
    //   • palette* (Primary/Secondary/Tertiary/Accent): general UI hierarchy
    //   • scoped* (Warning/CopySuccess): status glyph accents only — NEVER text
    // Text is always neutral (paletteSecondary). Status colour rides a
    // supplementary glyph beside the text, marked .accessibilityHidden(true)
    // so screen readers hear the status once from the words, not twice.
    // scopedSupportingText removed — its role duplicates paletteSecondary.
    // All ratios verified by contract test in Tests/I2ContractTests.swift.
    //
    // Opaque sRGB values per appearance; no opacity multiplier.
    private var scopedWarningText: Color {
        colorScheme == .dark ? Color(red: 0xFF/255, green: 0x9F/255, blue: 0x0A/255)
                              : Color(red: 0x60/255, green: 0x29/255, blue: 0x00/255)
    }
    private var scopedCopySuccessText: Color {
        colorScheme == .dark ? Color(red: 0x30/255, green: 0xD1/255, blue: 0x58/255)
                              : Color(red: 0x00/255, green: 0x45/255, blue: 0x12/255)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            // A3/A6: error banner only for stale (prior record retained).
            // F1: .failed now renders its own full diagnostic in failedSection.
            if case .stale = model.loadState {
                staleBanner(model.errorText ?? "Update failed")
            }
            Divider()
                .padding(.horizontal, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    mainContent
                }
                .padding(14)
            }
            .frame(height: 430)
            Divider()
                .padding(.horizontal, 14)
            footer
        }
        .frame(width: 340)
        .background(panelBackground)
    }

    /// A3/A6: route the main content area to the correct state-specific view.
    @ViewBuilder
    private var mainContent: some View {
        switch model.loadState {
        case .initial, .loading:
            ProgressView("Loading usage…")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
        case .noStores(let diagnostic):
            noStoresSection(diagnostic)
        case .unreadable(let diagnostic):
            unreadableSection(diagnostic)
        case .unrecognized(let diagnostic):
            unrecognizedSection(diagnostic)
        case .failed(let diagnostic):
            // First-run failure: show wrapped diagnostic with retry
            failedSection(diagnostic)
        case .noData:
            emptySection
        case .success, .stale:
            if let rec = model.record {
                if rec.hasLocalStats == false {
                    emptySection
                } else {
                    todaySection(rec)
                    weekSection(rec)
                    totalsSection(rec)
                    modelsSection(rec)
                    providersSection(rec)
                    accountsSection(rec)
                    workloadsSection(rec)
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: "chart.bar.fill")
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text("Hermes Agent Usage")
                    .font(.headline)
                Spacer()
                if model.isLoading {
                    ProgressView().controlSize(.small)
                }
            }
            Text("This Mac · All profiles")
                .font(.caption)
                .foregroundStyle(paletteSecondary)
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
    }

    /// A3: stale banner shows "Showing saved results; update failed"
    private func staleBanner(_ err: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(paletteAccentOrange)
                Text("Showing saved results; update failed")
                    .font(.caption.weight(.semibold))
                Spacer()
                Button("Retry") { model.refresh() }
                    .controlSize(.small)
            }
            Text(err)
                .font(.caption2)
                .foregroundStyle(paletteSecondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    /// A3: no stores found — friendly empty state
    private func noStoresSection(_ diagnostic: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("No local stores found", systemImage: "questionmark.circle")
                .font(.callout.weight(.semibold))
            Text("Hermes Agent hasn't created any session stores on this Mac yet.")
                .font(.caption)
                .foregroundStyle(paletteSecondary)
                .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 4) {
                    Text(diagnostic)
                        .font(.caption2)
                        .foregroundStyle(paletteSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .padding(.leading, 4)
            } label: {
                Text("Details")
                    .font(.caption2)
                    .foregroundStyle(paletteTertiary)
            }
            Button("Retry") { model.refresh() }
                .controlSize(.small)
                .padding(.top, 4)
        }
        .padding(.vertical, 12)
    }

    /// A3: stores exist but couldn't be read
    private func unreadableSection(_ diagnostic: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(paletteAccentOrange)
                    .accessibilityHidden(true)
                Text("Couldn't read local usage")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(palettePrimary)
            }
            Text("Session stores exist but couldn't be read. This is usually temporary.")
                .font(.caption)
                .foregroundStyle(paletteSecondary)
                .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 4) {
                    Text(diagnostic)
                        .font(.caption2)
                        .foregroundStyle(paletteSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .padding(.leading, 4)
            } label: {
                Text("Details")
                    .font(.caption2)
                    .foregroundStyle(paletteTertiary)
            }
            Button("Retry") { model.refresh() }
                .controlSize(.small)
                .padding(.top, 4)
        }
        .padding(.vertical, 12)
    }

    /// F1: first-run failure — full diagnostic visible as body text, not hidden
    /// behind a disclosure. The long reason and path must be fully readable at
    /// 340pt without hover, AX, or expanding a Details group.
    private func failedSection(_ diagnostic: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Update failed", systemImage: "exclamationmark.triangle")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.red)
            // F1: diagnostic as visible body text — not truncated, not hidden
            Text(diagnostic)
                .font(.caption)
                .foregroundStyle(paletteSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Button("Retry") { model.refresh() }
                .controlSize(.small)
                .padding(.top, 4)
        }
        .padding(.vertical, 12)
    }

    /// A6: valid JSON but not a valid usage record
    private func unrecognizedSection(_ diagnostic: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(paletteAccentOrange)
                    .accessibilityHidden(true)
                Text("Usage format not recognized")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(palettePrimary)
            }
            Text("The collector returned valid JSON, but it doesn't match the expected Hermes usage format.")
                .font(.caption)
                .foregroundStyle(paletteSecondary)
                .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 4) {
                    Text(diagnostic)
                        .font(.caption2)
                        .foregroundStyle(paletteSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .padding(.leading, 4)
            } label: {
                Text("Details")
                    .font(.caption2)
                    .foregroundStyle(paletteTertiary)
            }
            Button("Retry") { model.refresh() }
                .controlSize(.small)
                .padding(.top, 4)
        }
        .padding(.vertical, 12)
    }

    private var emptySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("No local Hermes usage found", systemImage: "questionmark.circle")
                .font(.callout.weight(.semibold))
            Text("Run a Hermes session on this Mac, then hit Refresh.")
                .font(.caption)
                .foregroundStyle(paletteSecondary)
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 2) {
                    Text("~/.hermes/state.db")
                    Text("~/.hermes/profiles/*/state.db")
                    Text("Scope: this device, all profiles · reads local databases; a rare fallback path may create an empty file if a store vanishes mid-scan")
                }
                .font(.caption2)
                .foregroundStyle(paletteSecondary)
                .padding(.leading, 4)
            } label: {
                Text("Stores being checked")
                    .font(.caption2)
                    .foregroundStyle(paletteTertiary)
            }
        }
        .padding(.vertical, 8)
    }

    private func todaySection(_ rec: UsageRecord) -> some View {
        let dayLabel = model.updatedAt.map { dayAgeLabel(updatedAt: $0) } ?? "unknown"
        return VStack(alignment: .leading, spacing: 4) {
            Label("\(dayLabel.capitalized) — estimated tokens", systemImage: "sun.max")
                .font(.subheadline.weight(.semibold))
                .help("Collection timestamp: \(model.updatedAt?.formatted(date: .complete, time: .shortened) ?? "unknown")")
            HStack(spacing: 14) {
                statCell(label: "Tokens",
                         value: compactTokens(Double(rec.todayTotalTokens ?? 0)),
                         help: rec.todayTotalTokens.map { exactTokens($0) })
                statCell(label: "Prompts",
                         value: rec.todayPrompts.map(String.init) ?? "—",
                         help: rec.todayPrompts.map { "\($0) prompts" })
                statCell(label: "Sessions",
                         value: rec.todaySessions.map(String.init) ?? "—",
                         help: rec.todaySessions.map { "\($0) sessions" })
            }
            if let byModel = rec.todayTokensByModel, !byModel.isEmpty {
                DisclosureGroup("By model") {
                    let sorted = byModel.sorted { $0.value > $1.value }
                    ForEach(Array(sorted.enumerated()), id: \.offset) { _, entry in
                        HStack {
                            Text(entry.key)
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(entry.key)
                            Spacer()
                            Text(compactTokens(Double(entry.value)))
                                .font(.caption.monospacedDigit())
                                .frame(width: 52, alignment: .trailing)
                                .help(exactTokens(entry.value))
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(entry.key), \(exactTokens(entry.value))")
                    }
                }
                .font(.caption.weight(.medium))
                .padding(.top, 2)
            }
        }
    }

    /// F4: one labelled metric per accessibility element. Combines value+label
    /// into a single Text so AX exposes "14.5M tokens" as one node.
    private func statCell(label: String, value: String, help: String?) -> some View {
        VStack(spacing: 1) {
            Text("\(value) \(label)")
                .font(.system(.title3, design: .rounded).weight(.bold))
                .monospacedDigit()
                .accessibilityLabel("\(value) \(label)")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
        .help(help ?? "")
    }

    private func weekSection(_ rec: UsageRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Last 7 days — estimated tokens", systemImage: "calendar")
                .font(.subheadline.weight(.semibold))
            if let days = rec.recentDays, !days.isEmpty {
                WeekBars(days: days, palettePrimary: palettePrimary, paletteSecondary: paletteSecondary)
            } else {
                Text("No data")
                    .font(.caption)
                    .foregroundStyle(paletteSecondary)
            }
        }
    }

    /// F6: totals section uses spec-mandated labels — "Collected history" (not
    /// "All-time"), "Reported calls" (not "Calls"), and qualified warnings that
    /// match the expanded disclosure wording.
    private func totalsSection(_ rec: UsageRecord) -> some View {
        let truncated = rec.details?.truncated == true
        let unknownCalls = rec.details?.totals?.unknownCallRows ?? 0
        return VStack(alignment: .leading, spacing: 6) {
            // F6: collection-status line ABOVE the metrics, qualified label
            if truncated {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(scopedWarningText)
                        .accessibilityHidden(true)
                    Text("Partial local collection — totals may omit older activity.")
                        .font(.caption2)
                        .foregroundStyle(paletteSecondary)
                }
            }
            Label(truncated ? "Collected history (partial)" : "Collected history", systemImage: "clock")
                .font(.subheadline.weight(.semibold))
                .help(truncated
                    ? "Totals from partial local collection — some older activity may be omitted."
                    : "Totals from complete local collection on this Mac.")
            HStack(spacing: 10) {
                let allTokens = rec.details?.totals?.tokens ?? rec.modelUsage?.values.map(\.totalTokens).reduce(0, +) ?? 0
                totalChip("Tokens", compactTokens(Double(allTokens)), help: exactTokens(allTokens))
                // F6: "Reported calls" not "Calls"
                totalChip("Reported calls", rec.details?.totals?.calls.map(String.init) ?? "—",
                          help: rec.details?.totals?.calls.map { "\($0) reported calls" } ?? "")
                totalChip("Est. USD", compactCost(rec.details?.totals?.estimatedUsd),
                          help: costHelp(rec.details?.totals?.estimatedUsd))
            }
            // R2: Total reasoning on its own full-width row below the 3-chip HStack
            if let reasoning = aggregateReasoning(rec) {
                HStack {
                    Text("Total reasoning")
                        .font(.caption2)
                        .foregroundStyle(paletteSecondary)
                    Spacer()
                    Text(tokenCountString(reasoning))
                        .font(.system(.callout, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
                .help("\(tokenCountString(reasoning)) reasoning tokens (aggregate, not per model)")
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Total reasoning \(tokenCountString(reasoning))")
            }
            // F6: qualified call-coverage warning matching the disclosure wording
            if unknownCalls > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(scopedWarningText)
                        .accessibilityHidden(true)
                    Text(formatCallCoverageWarning(unknownCallRows: unknownCalls))
                        .font(.caption2)
                        .foregroundStyle(paletteSecondary)
                }
            }
            Text("Estimated, not necessarily billed charges.")
                .font(.caption2)
                .foregroundStyle(paletteSecondary)
            if rec.details?.totals?.estimatedUsd == nil || hasNilProviderCost(rec) {
                Text("— Cost unavailable; not zero")
                    .font(.caption2)
                    .foregroundStyle(paletteSecondary)
                    .accessibilityLabel("Em-dash means cost unavailable; not zero")
            }

            // B3: Accounting evidence disclosure
            if let totals = rec.details?.totals {
                DisclosureGroup("How these costs are known") {
                    VStack(alignment: .leading, spacing: 6) {
                        if let estimated = totals.estimatedUsd {
                            Text("Recorded estimate (USD): \(compactCost(estimated))")
                                .font(.caption2)
                                .help(formatRecordedCost(estimated))
                            Text("Sum of provider-reported estimates; costs may be unreported by some providers.")
                                .font(.caption2)
                                .foregroundStyle(paletteSecondary)
                        } else {
                            Text("Recorded estimate (USD): unavailable")
                                .font(.caption2)
                                .help("Recorded estimate unavailable")
                        }

                        if let actual = totals.actualUsd {
                            Text("Recorded actual (USD): \(compactCost(actual))")
                                .font(.caption2)
                                .help(formatRecordedCost(actual))
                            Text("Sum of provider-reported actual costs; not invoice reconciliation.")
                                .font(.caption2)
                                .foregroundStyle(paletteSecondary)
                        }

                        if totals.estimatedUsd != nil && totals.actualUsd != nil {
                            HStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(scopedWarningText)
                                    .accessibilityHidden(true)
                                Text("Estimate and actual are separate facts. Do not sum them.")
                                    .font(.caption2)
                                    .foregroundStyle(paletteSecondary)
                            }
                        }

                        if let statusBreakdown = formatRowStatusBreakdown(totals.latestStatusRows) {
                            Text("Row status: \(statusBreakdown)")
                                .font(.caption2)
                                .foregroundStyle(paletteSecondary)
                            Text("Status counts describe observations, not coverage.")
                                .font(.caption2)
                                .foregroundStyle(paletteTertiary)
                        }

                        Text(formatCallAvailability(calls: totals.calls, unknownCallRows: totals.unknownCallRows))
                            .font(.caption2)
                            .foregroundStyle(paletteSecondary)
                    }
                    .padding(.vertical, 4)
                }
                .font(.caption2)
                .foregroundStyle(paletteSecondary)
            }
        }
    }

    private func costHelp(_ n: Double?) -> String {
        guard let n = n else { return "Cost unavailable; not zero — no estimate reported" }
        return "Recorded estimate: \(compactCost(n)); costs may be unreported by some providers"
    }

    // MARK: - B3: Accounting evidence helpers

    private func totalChip(_ label: String, _ value: String, help: String) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.system(.callout, design: .rounded).weight(.semibold))
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(paletteSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12)))
        .help(help)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label) \(value)")
    }

    private func modelsSection(_ rec: UsageRecord) -> some View {
        let rows = showAllModels ? allSortedModels(rec) : sortedModels(rec)
        let total = rec.modelUsage?.count ?? rows.count
        return DisclosureGroup {
            if rows.isEmpty {
                Text("No model data")
                    .font(.caption)
                    .foregroundStyle(paletteSecondary)
            } else {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    let (modelName, totalTokens) = row
                    let mu = rec.modelUsage?[modelName]
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(shortName(modelName))
                                .font(.caption)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(modelName)
                            Spacer()
                            Text(compactTokens(Double(totalTokens)))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(paletteSecondary)
                                .help(exactTokens(totalTokens))
                        }
                        if let mu = mu {
                            ViewThatFits {
                                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 2) {
                                    GridRow {
                                        HStack(spacing: 4) {
                                            Text("In:")
                                            Text(tokenCountString(mu.inputTokens ?? 0))
                                                .lineLimit(1)
                                                .minimumScaleFactor(0.7)
                                        }
                                        HStack(spacing: 4) {
                                            Text("Out:")
                                            Text(tokenCountString(mu.outputTokens ?? 0))
                                                .lineLimit(1)
                                                .minimumScaleFactor(0.7)
                                        }
                                    }
                                    GridRow {
                                        HStack(spacing: 4) {
                                            Text("Cache read:")
                                            Text(tokenCountString(mu.cacheReadInputTokens ?? 0))
                                                .lineLimit(1)
                                                .minimumScaleFactor(0.7)
                                        }
                                        HStack(spacing: 4) {
                                            Text("Cache write:")
                                            Text(tokenCountString(mu.cacheCreationInputTokens ?? 0))
                                                .lineLimit(1)
                                                .minimumScaleFactor(0.7)
                                                .help("Token components: some stores or providers may not record every component")
                                        }
                                    }
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 4) {
                                        Text("In:")
                                        Text(tokenCountString(mu.inputTokens ?? 0))
                                            .lineLimit(1)
                                    }
                                    HStack(spacing: 4) {
                                        Text("Out:")
                                        Text(tokenCountString(mu.outputTokens ?? 0))
                                            .lineLimit(1)
                                    }
                                    HStack(spacing: 4) {
                                        Text("Cache read:")
                                        Text(tokenCountString(mu.cacheReadInputTokens ?? 0))
                                            .lineLimit(1)
                                    }
                                    HStack(spacing: 4) {
                                        Text("Cache write:")
                                        Text(tokenCountString(mu.cacheCreationInputTokens ?? 0))
                                            .lineLimit(1)
                                            .help("Token components: some stores or providers may not record every component")
                                    }
                                }
                            }
                            .font(.caption2)
                            .foregroundStyle(paletteSecondary)
                        }
                    }
                    .padding(.vertical, 1)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(mu != nil ? formatModelAccessibilityLabel(modelName: modelName, mu: mu!) : "\(modelName), \(exactTokens(totalTokens))")
                }
                if total > 8 {
                    Button(showAllModels ? "Show fewer" : "Show all models (\(total))") {
                        showAllModels.toggle()
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                    .padding(.top, 2)
                }
                // R2: surface incomplete collection
                if let details = rec.details, details.truncated == true {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(scopedWarningText)
                            .accessibilityHidden(true)
                        Text("Partial collection")
                            .font(.caption2)
                            .foregroundStyle(paletteSecondary)
                    }
                    .padding(.top, 2)
                }
            }
        } label: {
            Label("Models (\(total)) — bounded local history", systemImage: "cpu")
                .font(.subheadline.weight(.semibold))
        }
    }

    private func allSortedModels(_ rec: UsageRecord) -> [(String, Int)] {
        guard let m = rec.modelUsage else { return [] }
        return m.map { ($0.key, $0.value.totalTokens) }
            .sorted { $0.1 > $1.1 }
    }

    private func sortedModels(_ rec: UsageRecord) -> [(String, Int)] {
        Array(allSortedModels(rec).prefix(8))
    }

    private func providersSection(_ rec: UsageRecord) -> some View {
        let rows = sortedProviders(rec)
        let total = rec.providerUsage?.count ?? rows.count
        // Pre-compute costs with proper nil handling (R3).
        // Use resolveProviderCost to normalize detail keys and avoid falling back to legacy zero.
        let rowsWithCost = rows.map { providerName, providerUsage in
            let cost = resolveProviderCost(rec: rec, providerName: providerName, legacyCost: providerUsage.estimatedCostUsd)
            return (providerName, providerUsage, cost)
        }
        return DisclosureGroup {
            if rows.isEmpty {
                Text("No provider data")
                    .font(.caption)
                    .foregroundStyle(paletteSecondary)
            } else {
                HStack {
                    Text("Provider")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Est. USD")
                        .frame(width: 64, alignment: .trailing)
                    Text("Tokens")
                        .frame(width: 52, alignment: .trailing)
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(paletteTertiary)
                .padding(.bottom, 2)
                ForEach(Array(rowsWithCost.enumerated()), id: \.offset) { _, row in
                    let (providerName, providerUsage, costUsd) = row
                    HStack {
                        Text(providerLabel(providerName))
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(providerName)
                        Spacer()
                        Text(compactCost(costUsd))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(paletteSecondary)
                            .frame(width: 64, alignment: .trailing)
                            .help(costHelp(costUsd))
                        Text(compactTokens(Double(providerUsage.tokens ?? 0)))
                            .font(.caption.monospacedDigit())
                            .frame(width: 52, alignment: .trailing)
                            .help(exactTokens(providerUsage.tokens ?? 0))
                    }
                    .padding(.vertical, 1)
                }
                // R2: surface incomplete collection
                if let details = rec.details, details.truncated == true {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(scopedWarningText)
                            .accessibilityHidden(true)
                        Text("Partial collection")
                            .font(.caption2)
                            .foregroundStyle(paletteSecondary)
                    }
                    .padding(.top, 2)
                }
            }
        } label: {
            Label("Providers (\(total)) — bounded local history", systemImage: "server.rack")
                .font(.subheadline.weight(.semibold))
        }
    }

    // MARK: - B6: Account quotas section

    /// B6: Account quota section showing per-provider quota windows or USD credit.
    /// Empty accounts array means no snapshot available (not that plugin is uninstalled
    /// or access denied). Preserves distinct states: unknown, zero, unavailable,
    /// denied, expired. Uses scoped contrast tokens to avoid reintroducing the
    /// supporting-text contrast failure being fixed in t_98d271e9.
    private func accountsSection(_ rec: UsageRecord) -> some View {
        let accounts = rec.accounts ?? []
        let freshAccounts = accounts.filter { isSnapshotFresh($0) }
        let total = accounts.count

        return DisclosureGroup {
            if accounts.isEmpty {
                // Empty accounts array: no quota snapshot available.
                // NOT that plugin is uninstalled, NOT that access denied.
                // Use neutral wording; reserve "denied" for explicit status.
                VStack(alignment: .leading, spacing: 4) {
                    Text("No quota snapshot available")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(palettePrimary)
                    Text("Account quotas are not yet observed. This does not indicate a plugin install or access issue.")
                        .font(.caption2)
                        .foregroundStyle(paletteSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            } else if freshAccounts.isEmpty {
                // All snapshots expired (past 600s TTL).
                VStack(alignment: .leading, spacing: 4) {
                    Text("Quota snapshots expired")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(palettePrimary)
                    Text("All observed quotas are past their freshness window (\(Int(accountQuotaTTL / 60)) min). Refresh to re-observe.")
                        .font(.caption2)
                        .foregroundStyle(paletteSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 4)
            } else {
                // Render fresh snapshots with quota windows or USD credit.
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(freshAccounts.enumerated()), id: \.offset) { _, snap in
                        accountSnapshotRow(snap)
                    }
                }
                .padding(.vertical, 4)
            }
        } label: {
            Label("Account quotas (\(total)) — observed windows", systemImage: "checkmark.circle")
                .font(.subheadline.weight(.semibold))
        }
    }

    /// B6: Render a single account snapshot row showing quota windows or USD credit,
    /// reset time, and freshness. Exactly one caveat per combined row.
    private func accountSnapshotRow(_ snap: AccountSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            // Provider name and access status
            HStack {
                Text(accountProviderLabel(snap.provider))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(palettePrimary)
                Spacer()
                if hasAccessRestriction(snap) {
                    // Only nous carries denied/member-cap-exceeded inside 600s window.
                    // Represent that asymmetry faithfully.
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(scopedWarningText)
                            .accessibilityHidden(true)
                        Text(formatAccessStatus(snap.accessStatus, provider: snap.provider))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(paletteSecondary)
                    }
                } else if snap.accessStatus == "allowed" {
                    Text("Allowed")
                        .font(.caption2)
                        .foregroundStyle(paletteSecondary)
                }
            }

            // Plan name if present
            if !snap.plan.isEmpty {
                Text(snap.plan)
                    .font(.caption2)
                    .foregroundStyle(paletteSecondary)
                    .lineLimit(1)
            }

            // Quota windows or USD credit
            if snap.available {
                if !snap.windows.isEmpty {
                    // Show quota windows (usedPercent, remainingPercent, resetAt)
                    ForEach(Array(snap.windows.enumerated()), id: \.offset) { _, window in
                        if isWindowResetPassed(window) {
                            // Window crossed resetAt while popover was open — don't show stale %
                            HStack {
                                Text(window.label)
                                    .font(.caption2)
                                    .foregroundStyle(paletteSecondary)
                                Spacer()
                                Text("reset passed — awaiting re-observation")
                                    .font(.caption2)
                                    .foregroundStyle(paletteTertiary)
                            }
                        } else {
                            HStack {
                                Text(window.label)
                                    .font(.caption2)
                                    .foregroundStyle(paletteSecondary)
                                Spacer()
                                Text(formatPercent(window.remainingPercent))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(palettePrimary)
                                Text(formatResetTime(window.resetAt))
                                    .font(.caption2)
                                    .foregroundStyle(paletteSecondary)
                                    .frame(width: 44, alignment: .trailing)
                            }
                        }
                    }
                } else if let usd = snap.remainingUsd, snap.currency == "USD" {
                    // Show USD credit (only nous provider per quota_io.py)
                    HStack {
                        Text("Remaining credit")
                            .font(.caption2)
                            .foregroundStyle(paletteSecondary)
                        Spacer()
                        Text(compactCost(usd))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(palettePrimary)
                    }
                }
            } else {
                // Status is "unavailable" — no windows, no USD
                Text("Quota unavailable")
                    .font(.caption2)
                    .foregroundStyle(paletteSecondary)
            }

            // Freshness indicator
            HStack {
                Text("Freshness:")
                    .font(.caption2)
                    .foregroundStyle(paletteTertiary)
                Text(snapshotFreshness(snap))
                    .font(.caption2)
                    .foregroundStyle(paletteSecondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accountAccessibilityLabel(snap))
    }

    /// B6: Format accessibility label for an account snapshot row.
    /// Combines provider, access status, quota windows or USD, and freshness.
    private func accountAccessibilityLabel(_ snap: AccountSnapshot) -> String {
        var parts: [String] = [accountProviderLabel(snap.provider)]

        if hasAccessRestriction(snap) {
            parts.append(formatAccessStatus(snap.accessStatus, provider: snap.provider))
        }

        if snap.available {
            if !snap.windows.isEmpty {
                for window in snap.windows {
                    parts.append(accountWindowAnnouncement(window))
                }
            } else if let usd = snap.remainingUsd, snap.currency == "USD" {
                parts.append("\(compactCost(usd)) remaining credit")
            }
        } else {
            parts.append("Quota unavailable")
        }

        parts.append("Freshness: \(snapshotFreshness(snap))")

        return parts.joined(separator: ", ")
    }

    // MARK: - B2: Workloads section

    /// B2: Workload/task breakdown section.
    /// Ranks collector-generated task labels by collected tokens, with calls and
    /// recorded estimates as secondary columns. Uses collector's labels directly
    /// (ordinary, unknown, other, or explicit task strings) without inferring
    /// profiles, doctors, patients, or scheduling status.
    private func workloadsSection(_ rec: UsageRecord) -> some View {
        let tasks = sortedTasks(rec)
        let total = rec.details?.tasks?.count ?? tasks.count

        return DisclosureGroup {
            if tasks.isEmpty {
                Text("No workload data")
                    .font(.caption)
                    .foregroundStyle(paletteSecondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    // F3: column headers so values have meaning
                    HStack {
                        Text("Task")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("Calls")
                            .frame(width: 56, alignment: .trailing)
                        Text("Tokens")
                            .frame(width: 44, alignment: .trailing)
                        Text("Est. USD")
                            .frame(width: 50, alignment: .trailing)
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(paletteTertiary)
                    .padding(.bottom, 2)

                    ForEach(tasks, id: \.name) { task in
                        HStack {
                            Text(taskLabel(task.name))
                                .font(.caption)
                                .foregroundStyle(palettePrimary)
                            Spacer()
                            if let calls = task.calls {
                                Text(compactTokens(Double(calls)))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(paletteSecondary)
                                    .frame(width: 56, alignment: .trailing)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                            } else {
                                Text("—")
                                    .font(.caption)
                                    .foregroundStyle(paletteSecondary)
                                    .frame(width: 56, alignment: .trailing)
                            }
                            if let tokens = task.tokens {
                                Text(compactTokens(Double(tokens)))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(paletteSecondary)
                                    .frame(width: 44, alignment: .trailing)
                            } else {
                                Text("—")
                                    .font(.caption)
                                    .foregroundStyle(paletteSecondary)
                                    .frame(width: 44, alignment: .trailing)
                            }
                            Text(compactCost(task.estimatedUsd))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(paletteSecondary)
                                .frame(width: 50, alignment: .trailing)
                                .help(costHelp(task.estimatedUsd))
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(formatWorkloadAccessibilitySummary(task))
                    }
                }

                if rec.details?.truncated == true {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(scopedWarningText)
                            .accessibilityHidden(true)
                        Text("Partial collection — some workload history may be missing")
                            .font(.caption2)
                            .foregroundStyle(paletteSecondary)
                    }
                    .padding(.top, 4)
                }
            }
        } label: {
            Label("Workloads (\(total)) — bounded collected history", systemImage: "list.bullet.rectangle")
                .font(.subheadline.weight(.semibold))
        }
        .help("Task categories recorded by the collector. This is bounded local history, not a complete inventory.")
    }

    /// B2: Sort tasks by tokens descending, with special ordering for collector-generated labels.
    private func sortedTasks(_ rec: UsageRecord) -> [(name: String, tokens: Int?, calls: Int?, estimatedUsd: Double?)] {
        guard let tasks = rec.details?.tasks else { return [] }

        // Sort by tokens descending, but ensure "other" and "unknown" appear last
        let sorted = tasks.sorted { lhs, rhs in
            let lhsPriority = taskSortPriority(lhs.key)
            let rhsPriority = taskSortPriority(rhs.key)
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }
            return (lhs.value.tokens ?? 0) > (rhs.value.tokens ?? 0)
        }

        return sorted.map { (name: $0.key, tokens: $0.value.tokens, calls: $0.value.calls, estimatedUsd: $0.value.estimatedUsd) }
    }

    private func sortedProviders(_ rec: UsageRecord) -> [(String, ProviderUsage)] {
        guard let p = rec.providerUsage else { return [] }
        return p.map { ($0.key, $0.value) }
            .sorted { ($0.1.tokens ?? 0) > ($1.1.tokens ?? 0) }
    }

    private func providerLabel(_ p: String) -> String {
        switch p {
        case "openai-codex": return "Codex"
        case "anthropic": return "Anthropic"
        case "nous": return "Nous"
        case "deepseek": return "DeepSeek"
        case "zai": return "Zhipu"
        case "meta-ai": return "Meta"
        case "xai": return "xAI"
        case "openrouter": return "OpenRouter"
        case "cerebras": return "Cerebras"
        default: return p
        }
    }

    private func shortName(_ model: String) -> String {
        // "deepseek/deepseek-v4-flash" -> "deepseek-v4-flash"
        if let slash = model.firstIndex(of: "/") {
            return String(model[model.index(after: slash)...])
        }
        return model
    }

    private var footer: some View {
        // R7: explicitly observe displayTick to re-render time-dependent UI
        let tick = model.displayTick
        let hasFeedback = clipboardCopied || clipboardError != nil
        return AnyView(
        VStack(spacing: 2) {
            // R3: reserved feedback row above the timestamp — no overlay
            if clipboardCopied {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(scopedCopySuccessText)
                        .accessibilityHidden(true)
                    Text("Copied to clipboard")
                        .font(.caption2)
                        .foregroundStyle(paletteSecondary)
                }
                .accessibilityLabel("Copied to clipboard")
            } else if let error = clipboardError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .accessibilityLabel(error)
            }
            HStack {
                if !hasFeedback {
                    if let t = model.updatedAt {
                        Text(footerAgeText(t))
                            .font(.caption2)
                            .foregroundStyle(paletteSecondary)
                            .help("Last successful update \(t.formatted(date: .complete, time: .standard)) · auto-refresh every 15 min")
                    } else {
                        Text("Not updated")
                            .font(.caption2)
                            .foregroundStyle(paletteSecondary)
                    }
                }
                Spacer()
                Button("Refresh") { model.refresh() }
                    .controlSize(.small)
                    .disabled(model.isLoading)
                    .keyboardShortcut("r", modifiers: .command)
                Menu {
                    Button("Copy usage summary") {
                        // Cancel any pending feedback timer
                        feedbackTimer?.cancel()
                    
                        if let rec = model.record {
                            let receipt = formatUsageReceipt(rec, loadState: model.loadState)
                            let pasteboard = NSPasteboard.general
                            pasteboard.clearContents()
                            if pasteboard.setString(receipt, forType: .string) {
                                // Success: clear error, set success, schedule timer
                                clipboardError = nil
                                clipboardCopied = true
                                let timer = DispatchWorkItem {
                                    clipboardCopied = false
                                }
                                feedbackTimer = timer
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: timer)
                            } else {
                                // Failure: clear success, set error, schedule timer
                                clipboardCopied = false
                                clipboardError = "Failed to write to clipboard"
                                let timer = DispatchWorkItem {
                                    clipboardError = nil
                                }
                                feedbackTimer = timer
                                DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: timer)
                            }
                        } else {
                            // No data: clear success, set error, schedule timer
                            clipboardCopied = false
                            clipboardError = "No usage data to copy"
                            let timer = DispatchWorkItem {
                                clipboardError = nil
                            }
                            feedbackTimer = timer
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: timer)
                        }
                    }
                    .disabled(model.record == nil)
                    Button("Quit Hermes Usage", role: .destructive) { NSApplication.shared.terminate(nil) }
                        .keyboardShortcut("q")
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 13))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More (copy summary or quit)")
            }
        }
        .padding(14)
        .onAppear { _ = tick }  // R7: bind observation
        )
    }

    private func footerAgeText(_ t: Date) -> String {
        // R7: reference displayTick so this re-renders on clock boundaries
        _ = model.displayTick
        if model.isStale {
            return "Last successful update \(relativeAgeFormatter.localizedString(for: t, relativeTo: Date()))"
        }
        if model.isDayStale {
            // R7: calculate actual days since update using calendar days (not 24-hour periods)
            let cal = Calendar.current
            let startT = cal.startOfDay(for: t)
            let startNow = cal.startOfDay(for: Date())
            let days = cal.dateComponents([.day], from: startT, to: startNow).day ?? 1
            let dayLabel = days == 1 ? "Yesterday's" : "\(days) days old"
            return "\(dayLabel) data · \(relativeAgeFormatter.localizedString(for: t, relativeTo: Date()))"
        }
        return "Updated \(relativeAgeFormatter.localizedString(for: t, relativeTo: Date())) · auto 15 min"
    }
}

extension ContentView {
    var startOnAppear: some View {
        onAppear { model.startIfNeeded(); model.refreshIfStale() }
    }
}

extension ModelUsage {
    var totalTokens: Int {
        (inputTokens ?? 0) + (outputTokens ?? 0) + (cacheReadInputTokens ?? 0) + (cacheCreationInputTokens ?? 0)
    }
}

// MARK: - B4: Token makeup

/// B4: Build accessibility label for a model row with token components.
func formatModelAccessibilityLabel(modelName: String, mu: ModelUsage, reasoning: Int? = nil) -> String {
    let total = mu.totalTokens
    var label = "\(modelName), \(tokenCountString(total)) total"
    let input = mu.inputTokens ?? 0
    let output = mu.outputTokens ?? 0
    let cacheRead = mu.cacheReadInputTokens ?? 0
    let cacheWrite = mu.cacheCreationInputTokens ?? 0
    label += ". Input \(tokenCountString(input)), Output \(tokenCountString(output)), Cache read \(tokenCountString(cacheRead)), Cache write \(tokenCountString(cacheWrite))"
    if let r = reasoning, r > 0 {
        label += ", Reasoning \(tokenCountString(r))"
    }
    return label
}

