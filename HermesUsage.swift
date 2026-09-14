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
}

struct Totals: Codable {
    let rows: Int?
    let calls: Int?
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

func compactCost(_ n: Double?) -> String {
    guard let n = n, n > 0 else { return "" }
    if n < 0.01 { return String(format: "$%.4f", n) }
    return String(format: "$%.2f", n)
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

// MARK: - Collector runner

struct CollectorError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@MainActor
final class UsageModel: ObservableObject {
    @Published var record: UsageRecord?
    @Published var errorText: String?
    @Published var updatedAt: Date?
    @Published var isLoading = false

    private var startedOnce = false

    init() {
        // Kick off collection immediately at launch, not on first popover open.
        startIfNeeded()
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

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        errorText = nil
        let path = collectorPath
        Task.detached(priority: .utility) {
            let result = Self.runCollector(path: path)
            await MainActor.run {
                self.isLoading = false
                switch result {
                case .success(let data):
                    let decoder = JSONDecoder()
                    if let rec = try? decoder.decode(UsageRecord.self, from: data) {
                        self.record = rec
                        self.updatedAt = Date()
                    } else {
                        self.errorText = "Could not parse collector output"
                    }
                case .failure(let err):
                    self.errorText = err.localizedDescription
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

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            ForEach(Array(days.enumerated()), id: \.offset) { idx, day in
                VStack(spacing: 3) {
                    Text(compactTokens(Double(day.messageCount)))
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(idx == days.count - 1 ? Color.accentColor : Color.secondary.opacity(0.45))
                        .frame(height: max(4, 44 * Double(day.messageCount) / maxTokens))
                    Text(weekdayLabel(day.date))
                        .font(.system(size: 9, weight: idx == days.count - 1 ? .bold : .regular))
                        .foregroundStyle(idx == days.count - 1 ? Color.primary : Color.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func weekdayLabel(_ dateStr: String) -> String {
        guard let d = dayParser.date(from: dateStr) else { return "" }
        return weekdayFormatter.string(from: d)
    }
}

// MARK: - Content view

struct ContentView: View {
    @EnvironmentObject var model: UsageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let err = model.errorText {
                Text("⚠️ \(err)")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let rec = model.record {
                if rec.hasLocalStats == false {
                    Text("No local Hermes usage found.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    todaySection(rec)
                    weekSection(rec)
                    modelsSection(rec)
                    totalsSection(rec)
                    providersSection(rec)
                }
            } else if model.errorText == nil {
                ProgressView("Loading usage…")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            footer
        }
        .padding(14)
        .frame(width: 340)
    }

    private var header: some View {
        HStack {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .foregroundStyle(Color.accentColor)
            Text("Hermes Agent Usage")
                .font(.headline)
            Spacer()
            if model.isLoading {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func todaySection(_ rec: UsageRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Today", systemImage: "sun.max")
                .font(.subheadline.weight(.semibold))
            HStack(spacing: 14) {
                statCell(label: "Tokens", value: compactTokens(Double(rec.todayTotalTokens ?? 0)))
                statCell(label: "Prompts", value: "\(rec.todayPrompts ?? 0)")
                statCell(label: "Sessions", value: "\(rec.todaySessions ?? 0)")
            }
        }
    }

    private func statCell(label: String, value: String) -> some View {
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
    }

    private func weekSection(_ rec: UsageRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Last 7 days", systemImage: "calendar")
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

    private func modelsSection(_ rec: UsageRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Models", systemImage: "cpu")
                .font(.subheadline.weight(.semibold))
            let rows = sortedModels(rec)
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
                        Spacer()
                        Text(compactTokens(Double(row.1)))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func sortedModels(_ rec: UsageRecord) -> [(String, Int)] {
        guard let m = rec.modelUsage else { return [] }
        return m.map { ($0.key, $0.value.totalTokens) }
            .sorted { $0.1 > $1.1 }
            .prefix(8)
            .map { $0 }
    }

    private func totalsSection(_ rec: UsageRecord) -> some View {
        HStack(spacing: 10) {
            totalChip("All-time", compactTokens(Double(rec.details?.totals?.tokens ?? rec.modelUsage?.values.map(\.totalTokens).reduce(0, +) ?? 0)))
            totalChip("Calls", "\(rec.details?.totals?.calls ?? 0)")
            totalChip("Est. cost", compactCost(rec.details?.totals?.estimatedUsd).isEmpty ? "$0" : compactCost(rec.details?.totals?.estimatedUsd))
        }
    }

    private func totalChip(_ label: String, _ value: String) -> some View {
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
    }

    private func providersSection(_ rec: UsageRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Providers", systemImage: "server.rack")
                .font(.subheadline.weight(.semibold))
            let rows = sortedProviders(rec)
            if rows.isEmpty {
                Text("No provider data")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack {
                        Text(providerLabel(row.0))
                            .font(.caption)
                        Spacer()
                        if let cost = row.1.estimatedCostUsd, cost > 0 {
                            Text(compactCost(cost))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Text(compactTokens(Double(row.1.tokens ?? 0)))
                            .font(.caption.monospacedDigit())
                            .frame(minWidth: 44, alignment: .trailing)
                    }
                }
            }
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
        HStack {
            if let t = model.updatedAt {
                Text("Updated \(t.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else {
                Text("—")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Refresh") { model.refresh() }
                .controlSize(.small)
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .controlSize(.small)
        }
    }
}

extension ContentView {
    var startOnAppear: some View {
        onAppear { model.startIfNeeded() }
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
                .onAppear { model.startIfNeeded() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "gauge.with.dots.needle.50percent")
                Text(statusText)
                    .font(.system(.body, design: .rounded, weight: .medium))
                    .monospacedDigit()
            }
            .accessibilityLabel("Hermes usage: \(statusText) tokens today")
        }
        .menuBarExtraStyle(.window)
    }

    private var statusText: String {
        if let rec = model.record, let t = rec.todayTotalTokens {
            return compactTokens(Double(t))
        }
        return "…"
    }
}
