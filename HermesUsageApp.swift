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

        // t_c9ec490a: standard About window, opened from the popover
        // footer's More menu. A real Window scene — not a popover section —
        // so it does not inherit ContentView's fixed 340 pt popover width,
        // auto-sizes with the content at large accessibility text sizes,
        // and is user-resizable (.contentMinSize).
        Window("About Hermes Usage", id: "about") {
            AboutPanel(version: .current)
        }
        .windowResizability(.contentMinSize)
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

    /// F8: menuBarHelp qualifies the snapshot date using dayAgeLabel, so the
    /// help text agrees with the status item AXTitle and the body heading.
    private var menuBarHelp: String {
        let age = dayAgeLabel(updatedAt: model.updatedAt)
        var parts: [String] = []
        if let rec = model.record, let t = rec.todayTotalTokens {
            parts.append("\(age.capitalized): \(exactTokens(t))")
        } else {
            parts.append("\(age.capitalized): —")
        }
        parts.append(scopeDescription(launchScope: model.launchScope))
        if let u = model.updatedAt {
            parts.append("Updated \(relativeAgeFormatter.localizedString(for: u, relativeTo: Date()))")
        }
        parts.append("Estimated, not billed")
        return parts.joined(separator: " · ")
    }
}

// MARK: - t_c9ec490a: About panel

/// Standard About panel: app name, one-line description, version, build,
/// and development status. Every version value comes from `AppVersion` —
/// the single bundle-plist reader the copied receipt uses — so the panel
/// adds no data path of its own. AX contract: each value is its own
/// `Text` (a real AXStaticText per value, never a merged blob or a drawn
/// glyph); the icon is decorative and AX-hidden. No fixed height and only
/// a minimum width, so the window grows with the content at large system
/// text sizes instead of clipping.
struct AboutPanel: View {
    let version: AppVersion

    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)

            VStack(spacing: 6) {
                Text("Hermes Usage")
                    .font(.title2.weight(.semibold))
                Text("Menu-bar summary of local Hermes Agent usage on this Mac.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
                .frame(width: 220)

            VStack(spacing: 8) {
                aboutRow(label: "Version", value: version.shortVersionDisplay)
                aboutRow(label: "Build", value: version.buildDisplay)
                aboutRow(label: "Status", value: version.statusDisplay)
            }
        }
        .padding(24)
        .frame(minWidth: 300)
    }

    /// One label Text + one value Text per row — two distinct AXStaticTexts,
    /// so screen readers announce each field separately.
    private func aboutRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer(minLength: 24)
            Text(value)
                .textSelection(.enabled)
        }
        .frame(maxWidth: 380, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
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
        dayAgeLabel(updatedAt: model.updatedAt)
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

    /// F8: menuBarHelp qualifies the snapshot date using dayAgeLabel, so the
    /// help text agrees with the status item AXTitle and the body heading.
    private var menuBarHelp: String {
        let age = dayAgeLabel(updatedAt: model.updatedAt)
        var parts: [String] = []
        if let rec = model.record, let t = rec.todayTotalTokens {
            parts.append("\(age.capitalized): \(exactTokens(t))")
        } else {
            parts.append("\(age.capitalized): —")
        }
        parts.append(scopeDescription(launchScope: model.launchScope))
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
