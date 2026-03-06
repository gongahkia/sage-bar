import SwiftUI

struct SettingsView: View {
    private enum SettingsPane: String, CaseIterable, Identifiable {
        case accounts
        case display
        case polling
        case analytics
        case integrations
        case automations
        case hotkey
        case sync
        case cli
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
            case .cli: return "CLI"
            case .diagnostics: return "Diagnostics"
            case .about: return "About"
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
            case .cli: return "terminal"
            case .diagnostics: return "ladybug"
            case .about: return "info.circle"
            }
        }
    }

    @State private var selectedPane: SettingsPane? = .accounts

    var body: some View {
        HStack(spacing: 0) {
            List(SettingsPane.allCases, selection: $selectedPane) { pane in
                Label(pane.title, systemImage: pane.systemImage)
                    .tag(Optional(pane))
            }
            .listStyle(.sidebar)
            .frame(minWidth: 190, idealWidth: 220, maxWidth: 240)

            Divider()

            Group {
                switch selectedPane ?? .accounts {
                case .accounts:
                    AccountsTab()
                case .display:
                    DisplayTab()
                case .polling:
                    PollingTab()
                case .analytics:
                    AnalyticsTab()
                case .integrations:
                    IntegrationsTab()
                case .automations:
                    AutomationsTab()
                case .hotkey:
                    HotkeyTab()
                case .sync:
                    SyncTab()
                case .cli:
                    CLITab()
                case .diagnostics:
                    DiagnosticsView()
                case .about:
                    AboutTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 860, height: 560)
    }
}
