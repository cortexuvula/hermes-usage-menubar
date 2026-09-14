import SwiftUI
import AppKit

// MARK: - Models (mirrors collector/hermes-usage.py JSON record)

struct UsageRecord: Codable {
    let id: String?
    let name: String?
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
/// R8: String(format: "%,.0f tokens", n) is not a valid printf conversion —
/// Swift's printf does not support the thousands-separator flag, so it
/// emitted the literal ",.0f tokens" text. Use NumberFormatter for proper
/// localized grouping.
func exactTokens(_ n: Double) -> String {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.maximumFractionDigits = 0
    f.minimumFractionDigits = 0
    f.groupingSeparator = ","
    f.usesGroupingSeparator = true
    let s = f.string(from: NSNumber(value: n)) ?? String(Int(n))
    return "\(s) tokens"
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

// MARK: - Collector runner

struct CollectorError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
final class UsageModel: ObservableObject {
    /// Distinct lifecycle states (R6). Separate "never loaded" from "failed
    /// with no prior record" so the menu bar can warn, and from "no data"
    /// so an empty install can show a deliberate empty state.
    enum LoadState: Equatable {
        case initial
        case loading
        case success
        case noData        // collector said hasLocalStats=false
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

    init() {
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

    private var collectorPath: String {
        Bundle.main.resourceURL!
            .appendingPathComponent("collector/hermes-usage.py").path
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
        // Retry initial failures and stale states
        if case .initial = loadState { refresh(); return }
        if case .failed = loadState { refresh(); return }
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
        return false
    }

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        errorText = nil
        loadState = .loading
        let path = collectorPath
        Task.detached(priority: .utility) {
            let result = Self.runCollector(path: path)
            await MainActor.run {
                self.isLoading = false
                switch result {
                case .success(let data):
                    let decoder = JSONDecoder()
                    if let rec = try? decoder.decode(UsageRecord.self, from: data) {
                        // R6: distinguish no-data from success
                        if rec.hasLocalStats == false {
                            self.loadState = .noData
                        } else {
                            self.loadState = .success
                        }
                        self.record = rec
                        self.updatedAt = Date()
                        self.isStale = false
                        self.errorText = nil
                    } else {
                        self.isStale = (self.record != nil)
                        self.errorText = "Could not parse collector output"
                        self.loadState = self.record != nil ? .stale("Could not parse collector output") : .failed("Could not parse collector output")
                    }
                case .failure(let err):
                    self.isStale = (self.record != nil)
                    self.errorText = err.localizedDescription
                    self.loadState = self.record != nil ? .stale(err.localizedDescription) : .failed(err.localizedDescription)
                }
            }
        }
    }

    private nonisolated static func runCollector(path: String) -> Result<Data, Error> {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        task.arguments = ["-B", path, "--force"]
        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        do {
            try task.run()
        } catch {
            return .failure(CollectorError(message: "Failed to start python3: \(error.localizedDescription)"))
        }
        task.waitUntilExit()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        if task.terminationStatus != 0 {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return .failure(CollectorError(message: "Collector exit \(task.terminationStatus): \(err.trimmingCharacters(in: .whitespacesAndNewlines))"))
        }
        return .success(data)
    }
}

// MARK: - Weekly bar chart

struct WeekBars: View {
    let days: [RecentDay]

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
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(fillColor(day))
                        .frame(height: barHeight(day))
                    Text(dayLabel(day.date))
                        .font(.caption.weight(isToday(day.date) ? .bold : .regular))
                        .foregroundStyle(isToday(day.date) ? Color.primary : Color.secondary)
                }
                .frame(maxWidth: .infinity)
                .help(barHelp(day))
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
        "\(day.date) · \(exactTokens(Double(day.messageCount)))"
    }
}

// MARK: - Content view

struct ContentView: View {
    @EnvironmentObject var model: UsageModel
    @State private var showAllModels = false

    var body: some View {
        VStack(spacing: 0) {
            header
            if let err = model.errorText {
                errorBanner(err)
            }
            Divider()
                .padding(.horizontal, 14)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let rec = model.record {
                        if rec.hasLocalStats == false {
                            emptySection
                        } else {
                            todaySection(rec)
                            weekSection(rec)
                            totalsSection(rec)
                            modelsSection(rec)
                            providersSection(rec)
                        }
                    } else if model.errorText == nil {
                        ProgressView("Loading usage…")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    }
                }
                .padding(14)
            }
            .frame(height: 430)
            Divider()
                .padding(.horizontal, 14)
            footer
        }
        .frame(width: 340)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: "chart.bar.fill")
                    .foregroundStyle(Color.accentColor)
                Text("Hermes Agent Usage")
                    .font(.headline)
                Spacer()
                if model.isLoading {
                    ProgressView().controlSize(.small)
                }
            }
            Text("This Mac · All profiles")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
    }

    private func errorBanner(_ err: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Update failed: \(err)")
                .font(.caption)
                .lineLimit(2)
            Spacer()
            Button("Retry") { model.refresh() }
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    private var emptySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("No local Hermes usage found", systemImage: "questionmark.circle")
                .font(.callout.weight(.semibold))
            Text("Run a Hermes session on this Mac, then hit Refresh.")
                .font(.caption)
                .foregroundStyle(.secondary)
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 2) {
                    Text("~/.hermes/state.db")
                    Text("~/.hermes/profiles/*/state.db")
                    Text("Scope: this device, all profiles · read-only")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
            } label: {
                Text("Stores being checked")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 8)
    }

    private func todaySection(_ rec: UsageRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Today — estimated tokens", systemImage: "sun.max")
                .font(.subheadline.weight(.semibold))
            HStack(spacing: 14) {
                statCell(label: "Tokens",
                         value: compactTokens(Double(rec.todayTotalTokens ?? 0)),
                         help: rec.todayTotalTokens.map { exactTokens(Double($0)) })
                statCell(label: "Prompts",
                         value: rec.todayPrompts.map(String.init) ?? "—",
                         help: rec.todayPrompts.map { "\($0) prompts" })
                statCell(label: "Sessions",
                         value: rec.todaySessions.map(String.init) ?? "—",
                         help: rec.todaySessions.map { "\($0) sessions" })
            }
        }
    }

    private func statCell(label: String, value: String, help: String?) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.system(.title3, design: .rounded).weight(.bold))
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
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
                WeekBars(days: days)
            } else {
                Text("No data")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func totalsSection(_ rec: UsageRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("All-time", systemImage: "clock")
                .font(.subheadline.weight(.semibold))
            HStack(spacing: 10) {
                let allTokens = rec.details?.totals?.tokens ?? rec.modelUsage?.values.map(\.totalTokens).reduce(0, +) ?? 0
                totalChip("Tokens", compactTokens(Double(allTokens)), help: exactTokens(Double(allTokens)))
                totalChip("Calls", rec.details?.totals?.calls.map(String.init) ?? "—",
                          help: rec.details?.totals?.calls.map { "\($0) calls" } ?? "")
                totalChip("Est. USD", compactCost(rec.details?.totals?.estimatedUsd),
                          help: costHelp(rec.details?.totals?.estimatedUsd))
            }
            // R2: surface incomplete collection and call coverage
            if let details = rec.details, details.truncated == true {
                Text("⚠️ Partial collection — some data was truncated")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            if let unknownCalls = rec.details?.totals?.unknownCallRows, unknownCalls > 0 {
                Text("⚠️ \(unknownCalls) call row\(unknownCalls == 1 ? "" : "s") with missing data")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            Text("Estimated, not necessarily billed charges.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func costHelp(_ n: Double?) -> String {
        guard let n = n else { return "Cost not observed" }
        return "Estimated cost USD \(compactCost(n))"
    }

    private func totalChip(_ label: String, _ value: String, help: String) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.system(.callout, design: .rounded).weight(.semibold))
                .monospacedDigit()
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.12)))
        .help(help)
    }

    private func modelsSection(_ rec: UsageRecord) -> some View {
        let rows = showAllModels ? allSortedModels(rec) : sortedModels(rec)
        let total = rec.modelUsage?.count ?? rows.count
        return DisclosureGroup {
            if rows.isEmpty {
                Text("No model data")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack {
                        Text(shortName(row.0))
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(row.0)
                        Spacer()
                        Text(compactTokens(Double(row.1)))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .help(exactTokens(Double(row.1)))
                    }
                    .padding(.vertical, 1)
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
                    Text("⚠️ Partial collection")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .padding(.top, 2)
                }
            }
        } label: {
            Label("Models (\(total)) — all time", systemImage: "cpu")
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
        return DisclosureGroup {
            if rows.isEmpty {
                Text("No provider data")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                .foregroundStyle(.tertiary)
                .padding(.bottom, 2)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    let providerName = row.0
                    let providerUsage = row.1
                    // R3: prefer detail data (nullable) over legacy field (coerces NULL to 0.0)
                    let detail = rec.details?.providers?[providerName]
                    let costUsd = detail?.estimatedUsd ?? providerUsage.estimatedCostUsd
                    HStack {
                        Text(providerLabel(providerName))
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(providerName)
                        Spacer()
                        Text(compactCost(costUsd))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 64, alignment: .trailing)
                            .help(costHelp(costUsd))
                        Text(compactTokens(Double(providerUsage.tokens ?? 0)))
                            .font(.caption.monospacedDigit())
                            .frame(width: 52, alignment: .trailing)
                            .help(exactTokens(Double(providerUsage.tokens ?? 0)))
                    }
                    .padding(.vertical, 1)
                }
                // R2: surface incomplete collection
                if let details = rec.details, details.truncated == true {
                    Text("⚠️ Partial collection")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .padding(.top, 2)
                }
            }
        } label: {
            Label("Providers (\(total)) — all time", systemImage: "server.rack")
                .font(.subheadline.weight(.semibold))
        }
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
        return AnyView(
        HStack {
            if let t = model.updatedAt {
                Text(footerAgeText(t))
                    .font(.caption2)
                    .foregroundStyle(model.isStale || model.isDayStale ? Color.orange : Color.secondary.opacity(0.6))
                    .help("Last successful update \(t.formatted(date: .complete, time: .standard)) · auto-refresh every 15 min")
            } else {
                Text("—")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Refresh") { model.refresh() }
                .controlSize(.small)
                .disabled(model.isLoading)
                .keyboardShortcut("r", modifiers: .command)
            Menu {
                Button("Quit Hermes Usage", role: .destructive) { NSApplication.shared.terminate(nil) }
                    .keyboardShortcut("q")
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 13))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More (⌘Q quits)")
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
            // R7: calculate actual days since update, not just "yesterday"
            let days = Calendar.current.dateComponents([.day], from: t, to: Date()).day ?? 1
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

// MARK: - App

@main
struct HermesUsageApp: App {
    @StateObject private var model = UsageModel()

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(model)
                .onAppear { model.startIfNeeded(); model.refreshIfStale() }
        } label: {
            // R7: explicitly observe displayTick to re-render menu bar label
            let tick = model.displayTick
            return AnyView(
            HStack(spacing: 4) {
                Image(systemName: model.menuBarWarning ? "exclamationmark.triangle.fill" : "chart.bar.fill")
                Text(statusText)
                    .font(.system(.body, design: .rounded, weight: .medium))
                    .monospacedDigit()
            }
            .help(menuBarHelp)
            .accessibilityLabel("Hermes usage: \(statusText) tokens today")
            .onAppear { _ = tick }
            )
        }
        .menuBarExtraStyle(.window)
    }

    private var statusText: String {
        if model.menuBarWarning, let rec = model.record, let t = rec.todayTotalTokens {
            return "⚠︎ " + compactTokens(Double(t))
        }
        if let rec = model.record, let t = rec.todayTotalTokens {
            return compactTokens(Double(t))
        }
        return "…"
    }

    private var menuBarHelp: String {
        var parts: [String] = []
        if let rec = model.record, let t = rec.todayTotalTokens {
            parts.append("Today: \(exactTokens(Double(t)))")
        } else {
            parts.append("Today: —")
        }
        parts.append("This Mac · all profiles")
        if let u = model.updatedAt {
            parts.append("Updated \(relativeAgeFormatter.localizedString(for: u, relativeTo: Date()))")
        }
        parts.append("Estimated, not billed")
        return parts.joined(separator: " · ")
    }
}
