import SwiftUI
import AppKit

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
            MenuBarLabelView(model: model)
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

// MARK: - Menu bar label view

struct MenuBarLabelView: View {
    @ObservedObject var model: UsageModel

    /// R7: day age derived from model.updatedAt (the @Published collection time),
    /// which is the only honest source of record age. Do NOT use activeDays
    /// (count of distinct activity days in history, not record age) or stale/
    /// refresh flags (a failed refresh does not age the data).
    private var dayLabel: String {
        if let t = model.updatedAt {
            let days = Calendar.current.dateComponents([.day], from: t, to: Date()).day ?? 0
            return days == 0 ? "today" : days == 1 ? "yesterday" : "\(days) days old"
        }
        return "age unknown"
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

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: model.menuBarWarning ? "exclamationmark.triangle.fill" : "chart.bar.fill")
            Text(statusText)
                .font(.system(.body, design: .rounded, weight: .medium))
                .monospacedDigit()
        }
        .help(menuBarHelp)
        .accessibilityLabel("Hermes usage: \(statusText) tokens \(dayLabel)")
    }
}
