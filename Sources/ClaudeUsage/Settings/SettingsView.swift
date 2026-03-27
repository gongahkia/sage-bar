import SwiftUI

struct SettingsView: View {
  enum SettingsPane: String, CaseIterable, Identifiable {
    case accounts
    case display
    case polling
    case analytics
    case integrations
    case automations
    case hotkey
    case sync
    case diagnostics
    case about
    var id: String { rawValue }

    var title: String {
      switch self {
      case .accounts: return "Accounts"
      case .display: return "Display"
      case .polling: return "Polling"
      case .analytics: return "Analytics"
      case .integrations: return "Integrations"
      case .automations: return "Automations"
      case .hotkey: return "Hotkey"
      case .sync: return "Sync"
      case .diagnostics: return "Diagnostics"
      case .about: return "About"
      }
    }

    var subtitle: String {
      switch self {
      case .accounts:
        return
          "Manage providers, validate connections, and control how each account participates in Sage Bar."
      case .display:
        return "Tune menu bar presentation, sparkline behavior, and the global keyboard shortcut."
      case .polling:
        return "Adjust refresh cadence for the app globally or on a per-provider basis."
      case .analytics:
        return "Configure forecasts, burn-rate alerts, reporting, and model-optimizer guidance."
      case .integrations:
        return "Review outgoing integrations and webhook-related behavior."
      case .automations:
        return "Define the rules that trigger commands, alerts, and follow-up actions."
      case .hotkey:
        return "Inspect the current shortcut state and adjust advanced hotkey behavior."
      case .sync:
        return "Manage iCloud sync and the data-sharing behavior between Sage Bar instances."
      case .diagnostics:
        return "Inspect runtime signals, health information, and local debugging output."
      case .about:
        return "Versioning, authorship, and project links for the current build."
      }
    }

    var systemImage: String {
      switch self {
      case .accounts: return "person.2"
      case .display: return "display"
      case .polling: return "clock"
      case .analytics: return "chart.bar"
      case .integrations: return "link"
      case .automations: return "gearshape.2"
      case .hotkey: return "keyboard"
      case .sync: return "icloud"
      case .diagnostics: return "ladybug"
      case .about: return "info.circle"
      }
    }
  }

  @State private var selectedPane: SettingsPane? = .accounts

  private var activePane: SettingsPane {
    selectedPane ?? .accounts
  }

  var body: some View {
    NavigationSplitView {
      List(SettingsPane.allCases, selection: $selectedPane) { pane in
        Label(pane.title, systemImage: pane.systemImage)
          .tag(Optional(pane))
          .padding(.vertical, 4)
      }
      .listStyle(.sidebar)
      .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 260)
    } detail: {
      VStack(spacing: 0) {
        SettingsPaneHeader(pane: activePane)
        Divider()
        detailView(for: activePane)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }
      .background(Color(nsColor: .windowBackgroundColor))
    }
    .navigationSplitViewStyle(.balanced)
    .frame(width: 960, height: 620)
    .background(Color(nsColor: .windowBackgroundColor))
  }

  @ViewBuilder
  private func detailView(for pane: SettingsPane) -> some View {
    switch pane {
    case .accounts: AccountsTab()
    case .display: DisplayTab()
    case .polling: PollingTab()
    case .analytics: AnalyticsTab()
    case .integrations: IntegrationsTab()
    case .automations: AutomationsTab()
    case .hotkey: HotkeyTab()
    case .sync: SyncTab()
    case .diagnostics: DiagnosticsView()
    case .about: AboutTab()
    }
  }
}

private struct SettingsPaneHeader: View {
  let pane: SettingsView.SettingsPane

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Label(pane.title, systemImage: pane.systemImage)
        .font(.system(size: 24, weight: .semibold))

      Text(pane.subtitle)
        .font(.callout)
        .foregroundColor(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 28)
    .padding(.vertical, 24)
    .background(
      LinearGradient(
        colors: [
          Color.accentColor.opacity(0.14),
          Color.accentColor.opacity(0.04),
          // swiftlint:disable:next trailing_comma
          Color.clear,
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )
    )
  }
}
