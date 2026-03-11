import AppKit
import SwiftUI

// MARK: – About Tab

struct AboutTab: View {
    var body: some View {
        VStack {
            Spacer()
            VStack(spacing: 12) {
                if let wizardIcon {
                    Image(nsImage: wizardIcon)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 160, height: 160)
                }

                Text("Sage Bar").font(.largeTitle).fontWeight(.bold)
                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                    .foregroundColor(.secondary)
                Text("Data sources: Claude Code local logs, Anthropic Workspace API")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                Link("GitHub", destination: URL(string: "https://github.com")!)

                HStack(spacing: 6) {
                    Text("Made with")
                    if let loveIcon {
                        Image(nsImage: loveIcon)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 16, height: 16)
                    }
                    Text("by")
                    Link("Gabriel Ong", destination: URL(string: "https://gabrielongzm.com")!)
                }
                .font(.caption)
                .padding(.top, 8)
            }
            .frame(maxWidth: 420)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
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
}
