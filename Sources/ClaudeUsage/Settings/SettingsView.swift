import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            AccountsTab().tabItem { Label("Accounts", systemImage: "person.2") }
            DisplayTab().tabItem { Label("Display", systemImage: "display") }
            PollingTab().tabItem { Label("Polling", systemImage: "clock") }
            AnalyticsTab().tabItem { Label("Analytics", systemImage: "chart.bar") }
            IntegrationsTab().tabItem { Label("Integrations", systemImage: "link") }
            AutomationsTab().tabItem { Label("Automations", systemImage: "gearshape.2") }
            HotkeyTab().tabItem { Label("Hotkey", systemImage: "keyboard") }
            SyncTab().tabItem { Label("Sync", systemImage: "icloud") }
            CLITab().tabItem { Label("CLI", systemImage: "terminal") }
            DiagnosticsView().tabItem { Label("Diagnostics", systemImage: "ladybug") }
            AboutTab().tabItem { Label("About", systemImage: "info.circle") }
        }.frame(width: 600, height: 480)
    }
}
