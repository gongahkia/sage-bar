import SwiftUI

// MARK: – Display Tab

struct DisplayTab: View {
    @State private var config = ConfigManager.shared.load()

    var body: some View {
        Form {
            Section("Menu Bar") {
                Picker("Style", selection: $config.display.menubarStyle) {
                    Text("Icon only").tag("icon")
                    Text("Show cost").tag("cost")
                    Text("Show tokens").tag("tokens")
                }
                Toggle("Show badge", isOn: $config.display.showBadge)
                Toggle("Compact mode", isOn: $config.display.compactMode)
                Toggle("Dual icon (2 accounts)", isOn: $config.display.dualIcon)
            }
            Section("Sparkline") {
                Toggle("Enable sparkline icon", isOn: $config.sparkline.enabled)
                Picker("Style", selection: $config.sparkline.style) {
                    Text("Cost").tag("cost")
                    Text("Tokens").tag("tokens")
                }
                Stepper("Window: \(config.sparkline.windowHours)h", value: $config.sparkline.windowHours, in: 24...720, step: 24)
                Stepper("Resolution: \(config.sparkline.resolution) pts", value: $config.sparkline.resolution, in: 12...48)
            }
            Section("Hotkey") {
                Toggle("Enable global hotkey", isOn: $config.hotkey.enabled)
                HStack {
                    Text("Binding:")
                    Text(hotkeyLabel).fontWeight(.medium)
                }
            }
        }.onChange(of: config.display) { _ in ConfigManager.shared.save(config) }
         .onChange(of: config.sparkline) { _ in ConfigManager.shared.save(config) }
         .onChange(of: config.hotkey) { _ in
             ConfigManager.shared.save(config)
             HotkeyManager.shared.register(config: config.hotkey, advancedConfig: config.hotkeyConfig)
         }
         .padding()
    }

    private var hotkeyLabel: String {
        let mods = config.hotkey.modifiers.map { $0 == "option" ? "⌥" : $0 == "command" ? "⌘" : $0 }.joined()
        return "\(mods)\(config.hotkey.key.uppercased())"
    }
}
