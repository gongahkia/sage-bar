import SwiftUI

// MARK: – About Tab

struct AboutTab: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("Claude Usage").font(.largeTitle).fontWeight(.bold)
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")")
                .foregroundColor(.secondary)
            Text("Data sources: Claude Code local logs, Anthropic Workspace API")
                .font(.caption).multilineTextAlignment(.center)
            Link("GitHub", destination: URL(string: "https://github.com")!)
        }.padding()
    }
}
