import AppKit
import SwiftUI

// MARK: – About Tab

struct AboutTab: View {
    var body: some View {
        VStack {
            HStack(spacing: 34) {
                if let wizardIcon {
                    Image(nsImage: wizardIcon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 138, height: 138)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Sage Bar")
                        .font(.system(size: 34, weight: .bold))
                    Text("Version \(versionText)")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal.fill")
                            .foregroundStyle(.teal)
                        Text("Menu bar utility")
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 13, weight: .medium))
                }

                Spacer(minLength: 24)

                VStack(spacing: 12) {
                    Button("What's New") {
                        openURL("https://github.com/gongahkia/sage-bar/releases")
                    }
                    Button("GitHub") {
                        openURL("https://github.com/gongahkia/sage-bar")
                    }
                    Button("Support") {
                        openURL("https://gabrielongzm.com")
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .frame(width: 190)
            }
            .padding(34)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(38)
    }

    private var versionText: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    private var wizardIcon: NSImage? {
        guard let url = Bundle.module.url(forResource: "WizardAboutIcon", withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }

    private var loveIcon: NSImage? {
        guard let url = Bundle.module.url(forResource: "LoveIcon", withExtension: "png") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }

    private func openURL(_ rawValue: String) {
        guard let url = URL(string: rawValue) else { return }
        NSWorkspace.shared.open(url)
    }
}
