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
            // R7: explicitly observe displayTick to re-render menu bar label
            _ = model.displayTick
            let dayLabel: String
            if model.isDayStale, let days = model.record?.activeDays, days >= 2 {
                dayLabel = "\(days) days old"
            } else if model.isStale {
                dayLabel = "yesterday"
            } else {
                dayLabel = "today"
            }
            return AnyView(
            HStack(spacing: 4) {
                Image(systemName: model.menuBarWarning ? "exclamationmark.triangle.fill" : "chart.bar.fill")
                Text(statusText)
                    .font(.system(.body, design: .rounded, weight: .medium))
                    .monospacedDigit()
            }
            .help(menuBarHelp)
            .accessibilityLabel("Hermes usage: \(statusText) tokens \(dayLabel)")
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
