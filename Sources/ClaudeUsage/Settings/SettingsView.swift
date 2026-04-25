import SwiftUI

struct SettingsView: View {
  enum SettingsPane: String, CaseIterable, Identifiable {
    case display
    case accounts
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
      case .display: return "General"
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
        return "Manage providers and account participation."
      case .display:
        return "Tune menu bar presentation and launch behavior."
      case .polling:
        return "Adjust refresh cadence."
      case .analytics:
        return "Forecasts, reporting, and cost guidance."
      case .integrations:
        return "Outgoing integrations and webhooks."
      case .automations:
        return "Rules that trigger actions."
      case .hotkey:
        return "Keyboard shortcut behavior."
      case .sync:
        return "iCloud and data sharing."
      case .diagnostics:
        return "Runtime health and logs."
      case .about:
        return "Version and project links."
      }
    }

    var systemImage: String {
      switch self {
      case .accounts: return "person.2"
      case .display: return "menubar.rectangle"
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

  @State private var selectedPane: SettingsPane = .display

  var body: some View {
    VStack(spacing: 0) {
      VStack(spacing: 14) {
        Text(selectedPane.title)
          .font(.system(size: 18, weight: .semibold))

        HStack(alignment: .top, spacing: 10) {
          ForEach(SettingsPane.allCases) { pane in
            SettingsToolbarItem(
              pane: pane,
              isSelected: pane == selectedPane
            ) {
              selectedPane = pane
            }
          }
        }
      }
      .padding(.top, 12)
      .padding(.bottom, 14)
      .frame(maxWidth: .infinity)
      .background(.bar)

      Divider()

      detailView(for: selectedPane)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .windowBackgroundColor))
    }
    .frame(width: 880, height: 580)
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

private struct SettingsToolbarItem: View {
  let pane: SettingsView.SettingsPane
  let isSelected: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      VStack(spacing: 6) {
        Image(systemName: pane.systemImage)
          .font(.system(size: 21, weight: .semibold))
          .symbolRenderingMode(.monochrome)
          .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
          .frame(width: 34, height: 34)
          .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
              .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
          )

        Text(pane.title)
          .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
          .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
          .lineLimit(1)
      }
      .frame(width: 72)
      .padding(.vertical, 6)
      .background(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
          .fill(isSelected ? Color(nsColor: .controlBackgroundColor) : Color.clear)
      )
    }
    .buttonStyle(.plain)
  }
}
