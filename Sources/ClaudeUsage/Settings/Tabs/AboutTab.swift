import SwiftUI

// MARK: – About Tab

struct AboutTab: View {
    var body: some View {
        VStack {
            Spacer()
            VStack(spacing: 12) {
                Image("WizardAboutIcon", bundle: .module)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 160, height: 160)

                Text("Sage Bar").font(.largeTitle).fontWeight(.bold)
                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                    .foregroundColor(.secondary)
                Text("Data sources: Claude Code local logs, Anthropic Workspace API")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                Link("GitHub", destination: URL(string: "https://github.com")!)
            }
            .frame(maxWidth: 420)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}
