import SwiftUI

// MARK: – Display Tab

struct DisplayTab: View {
    @State private var config = ConfigManager.shared.load()

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                NativeSettingsGroup {
                    NativeSettingsRow(
                        icon: "menubar.rectangle",
                        iconColor: .teal,
                        title: "Menu bar display",
                        subtitle: "Controls the single Sage Bar item."
                    ) {
                        Picker("", selection: $config.display.menubarStyle) {
                            Text("Icon").tag("icon")
                            Text("Cost").tag("cost")
                            Text("Tokens").tag("tokens")
                        }
                        .labelsHidden()
                        .frame(width: 120)
                    }

                    NativeSettingsRow(
                        icon: "circlebadge.fill",
                        iconColor: .green,
                        title: "Show status badge",
                        subtitle: "Keeps the health dot visible."
                    ) {
                        Toggle("", isOn: $config.display.showBadge)
                            .labelsHidden()
                    }

                    NativeSettingsRow(
                        icon: "rectangle.2.swap",
                        iconColor: .indigo,
                        title: "Dual menu bar items",
                        subtitle: "Only available with exactly two active accounts."
                    ) {
                        Toggle("", isOn: $config.display.dualIcon)
                            .labelsHidden()
                    }
                }

                NativeSettingsGroup {
                    NativeSettingsRow(
                        icon: "waveform.path.ecg",
                        iconColor: .orange,
                        title: "Sparkline icon",
                        subtitle: "Draws recent usage in the menu bar."
                    ) {
                        Toggle("", isOn: $config.sparkline.enabled)
                            .labelsHidden()
                    }

                    NativeSettingsRow(
                        icon: "chart.xyaxis.line",
                        iconColor: .blue,
                        title: "Sparkline metric"
                    ) {
                        Picker("", selection: $config.sparkline.style) {
                            Text("Cost").tag("cost")
                            Text("Tokens").tag("tokens")
                        }
                        .labelsHidden()
                        .frame(width: 110)
                        .disabled(!config.sparkline.enabled)
                    }

                    NativeSettingsRow(
                        icon: "clock.arrow.circlepath",
                        iconColor: .gray,
                        title: "Sparkline window",
                        subtitle: "\(config.sparkline.windowHours) hours, \(config.sparkline.resolution) points"
                    ) {
                        VStack(alignment: .trailing, spacing: 8) {
                            Stepper("", value: $config.sparkline.windowHours, in: 24...720, step: 24)
                                .labelsHidden()
                                .disabled(!config.sparkline.enabled)
                            Stepper("", value: $config.sparkline.resolution, in: 12...48)
                                .labelsHidden()
                                .disabled(!config.sparkline.enabled)
                        }
                    }
                }

                NativeSettingsGroup {
                    NativeSettingsRow(
                        icon: "keyboard",
                        iconColor: .purple,
                        title: "Global hotkey",
                        subtitle: hotkeyLabel
                    ) {
                        Toggle("", isOn: $config.hotkey.enabled)
                            .labelsHidden()
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: 780)
            .frame(maxWidth: .infinity)
        }
        .onChange(of: config.display) { _ in ConfigManager.shared.save(config) }
        .onChange(of: config.sparkline) { _ in ConfigManager.shared.save(config) }
        .onChange(of: config.hotkey) { _ in
            ConfigManager.shared.save(config)
            HotkeyManager.shared.register(config: config.hotkey, advancedConfig: config.hotkeyConfig)
        }
    }

    private var hotkeyLabel: String {
        let mods = config.hotkey.modifiers.map { $0 == "option" ? "⌥" : $0 == "command" ? "⌘" : $0 }.joined()
        return "\(mods)\(config.hotkey.key.uppercased())"
    }
}

private struct NativeSettingsGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
        )
    }
}

private struct NativeSettingsRow<Accessory: View>: View {
    let icon: String
    let iconColor: Color
    let title: String
    var subtitle: String?
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(iconColor.gradient)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15))
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 20)
            accessory
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .overlay(alignment: .bottom) {
            Divider()
                .padding(.leading, 64)
        }
    }
}
