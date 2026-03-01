import SwiftUI

// MARK: – CLI Tab

struct CLITab: View {
    @State private var config = ConfigManager.shared.load()
    @State private var copyFeedback = false
    @State private var isInstalling = false
    @State private var lastInstallError: String? = UserDefaults.standard.string(forKey: "lastCLIInstallError")

    private let snippet = "claude-usage"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("CLI Binary").font(.headline)
            Text("Install the claude-usage binary to access usage data from the terminal.")
            Button(isInstalling ? "Installing..." : "Install to /usr/local/bin") { installCLI() }
                .disabled(isInstalling)
            if let lastInstallError, !lastInstallError.isEmpty {
                Text(lastInstallError)
                    .font(.caption2)
                    .foregroundColor(.red)
                    .textSelection(.enabled)
            }

            Divider()

            Text("Shell Integration").font(.headline)
            HStack {
                TextField("", text: .constant(snippet)).textFieldStyle(.roundedBorder).disabled(true)
                Button(copyFeedback ? "Copied!" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(snippet, forType: .string)
                    copyFeedback = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copyFeedback = false }
                }
            }

            Divider()
            Text("TUI Layout").font(.headline)
            List {
                ForEach(Array(config.tui.layout.enumerated()), id: \.element) { _, field in
                    Text(field)
                }
                .onMove { from, to in
                    config.tui.layout.move(fromOffsets: from, toOffset: to)
                    ConfigManager.shared.save(config)
                }
            }.frame(height: 200)
        }.padding()
    }

    private func installCLI() {
        guard let cliBinary = packagedCLIBinaryURL() else {
            let msg = "Bundled CLI binary not found in app bundle."
            lastInstallError = msg
            UserDefaults.standard.set(msg, forKey: "lastCLIInstallError")
            return
        }
        let dest = URL(fileURLWithPath: "/usr/local/bin/claude-usage")
        isInstalling = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = runInstallCommand(source: cliBinary, destination: dest)
            DispatchQueue.main.async {
                isInstalling = false
                if result.success {
                    lastInstallError = nil
                    UserDefaults.standard.removeObject(forKey: "lastCLIInstallError")
                } else {
                    let message = result.message ?? "CLI install failed."
                    lastInstallError = message
                    UserDefaults.standard.set(message, forKey: "lastCLIInstallError")
                }
            }
        }
    }

    private func packagedCLIBinaryURL() -> URL? {
        let fm = FileManager.default
        let candidates: [URL?] = [
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("claude-usage"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/claude-usage"),
            Bundle.main.resourceURL?.appendingPathComponent("claude-usage"),
        ]
        return candidates
            .compactMap { $0 }
            .first(where: { fm.isExecutableFile(atPath: $0.path) })
    }

    private func runInstallCommand(source: URL, destination: URL) -> (success: Bool, message: String?) {
        let script = "cp '\(source.path)' '\(destination.path)' && chmod +x '\(destination.path)'"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", script]
        let outputPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = outputPipe

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return (false, "CLI install failed to start: \(error.localizedDescription)")
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard task.terminationStatus == 0 else {
            if !output.isEmpty { return (false, output) }
            return (false, "CLI install failed with exit code \(task.terminationStatus).")
        }
        return (true, nil)
    }
}

