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

    @State private var selectedPane: SettingsPane = .accounts

    var body: some View {
        HStack(spacing: 0) {
            // sidebar
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(SettingsPane.allCases) { pane in
                        Button(action: { selectedPane = pane }) {
                            HStack(spacing: 8) {
                                Image(systemName: pane.systemImage)
                                    .frame(width: 20)
                                Text(pane.title)
                                Spacer()
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(selectedPane == pane ? Color.accentColor.opacity(0.2) : Color.clear)
                            )
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(selectedPane == pane ? .accentColor : .primary)
                    }
                }
                .padding(8)
            }
            .frame(width: 180)
            .background(Color(nsColor: .controlBackgroundColor))
            Divider()
            // detail
            detailView
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(width: 860, height: 560)
    }

    @ViewBuilder
    private var detailView: some View {
        switch selectedPane {
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
