import SwiftUI

// MARK: – Automations Tab

struct AutomationsTab: View {
    @State private var config = ConfigManager.shared.load()
    @State private var showAdd = false

    var body: some View {
        VStack(alignment: .leading) {
            List {
                ForEach(config.automations) { rule in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(rule.name).fontWeight(.medium)
                            Text("\(rule.triggerType) > \(rule.threshold)").font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(
                            get: { rule.enabled },
                            set: { v in
                                if let i = config.automations.firstIndex(where: { $0.id == rule.id }) {
                                    config.automations[i].enabled = v
                                    ConfigManager.shared.save(config)
                                }
                            }
                        )).labelsHidden()
                    }
                }.onDelete { idx in
                    config.automations.remove(atOffsets: idx)
                    ConfigManager.shared.save(config)
                }
            }
            Button("+ Add Rule") { showAdd = true }.padding()
        }
        .sheet(isPresented: $showAdd) {
            AddAutomationSheet { rule in
                config.automations.append(rule)
                ConfigManager.shared.save(config)
            }
        }
    }
}

struct AddAutomationSheet: View {
    var onSave: (AutomationRule) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var triggerType = "cost_gt"
    @State private var threshold = ""
    @State private var shellCommand = ""
    @State private var testOutput = ""
    @State private var commandError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New Automation").font(.headline)
            TextField("Name", text: $name)
            Picker("Trigger", selection: $triggerType) {
                Text("Cost >").tag("cost_gt")
                Text("Tokens >").tag("tokens_gt")
            }.pickerStyle(.segmented)
            TextField("Threshold", text: $threshold)
            TextField("Shell command", text: $shellCommand)
                .onChange(of: shellCommand) { cmd in
                    commandError = AutomationEngine.validateCommand(cmd)
                }
            if let err = commandError {
                Text(err).foregroundColor(.red).font(.caption)
            }
            if !testOutput.isEmpty {
                ScrollView { Text(testOutput).font(.system(.caption, design: .monospaced)) }
                    .frame(height: 60).border(Color.gray)
            }
            HStack {
                Button("Run Now (test)") {
                    guard let d = Double(threshold) else { return }
                    let rule = AutomationRule(name: name, triggerType: triggerType, threshold: d, shellCommand: shellCommand)
                    Task {
                        let out = await AutomationEngine.testRun(rule: rule)
                        await MainActor.run { testOutput = out }
                    }
                }.disabled(shellCommand.isEmpty || commandError != nil)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    guard let d = Double(threshold), !name.isEmpty, !shellCommand.isEmpty, commandError == nil else { return }
                    let rule = AutomationRule(name: name, triggerType: triggerType, threshold: d, shellCommand: shellCommand)
                    onSave(rule)
                    dismiss()
                }.disabled(commandError != nil)
            }
        }.padding().frame(width: 380)
    }
}

