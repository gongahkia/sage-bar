import SwiftUI

// MARK: – Automations Tab

struct AutomationsTab: View {
    @State private var config = ConfigManager.shared.load()
    @State private var showAdd = false
    @State private var recentHistoryByRule: [UUID: [AutomationRunRecord]] = [:]

    private var activeAccounts: [Account] {
        Account.activeAccounts(in: config)
    }

    var body: some View {
        VStack(alignment: .leading) {
            List {
                ForEach(config.automations) { rule in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(rule.name).fontWeight(.medium)
                                Text("\(triggerDescription(rule)) • \(actionDescription(rule))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(scopeDescription(rule))
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { rule.enabled },
                                set: { value in
                                    if let index = config.automations.firstIndex(where: { $0.id == rule.id }) {
                                        config.automations[index].enabled = value
                                        ConfigManager.shared.save(config)
                                    }
                                }
                            ))
                            .labelsHidden()
                        }
                        if let latestRecord = recentHistoryByRule[rule.id]?.first {
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: latestRecord.success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                    .foregroundColor(latestRecord.success ? .green : .orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(latestRecord.dryRun ? "Last preview" : "Last run")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    Text(latestRecord.message)
                                        .font(.caption2)
                                    Text("\(latestRecord.timestamp.formatted(date: .abbreviated, time: .shortened))\(latestRecord.accountName.map { " • \($0)" } ?? "")")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onDelete { offsets in
                    config.automations.remove(atOffsets: offsets)
                    ConfigManager.shared.save(config)
                }
            }
            Button("+ Add Rule") { showAdd = true }
                .padding()
        }
        .task {
            await loadRecentHistory()
        }
        .onReceive(NotificationCenter.default.publisher(for: .automationRunHistoryDidChange)) { _ in
            Task { await loadRecentHistory() }
        }
        .sheet(isPresented: $showAdd) {
            AddAutomationSheet(accounts: activeAccounts) { rule in
                config.automations.append(rule)
                ConfigManager.shared.save(config)
            }
        }
    }

    private func loadRecentHistory() async {
        let records = await AutomationRunHistoryStore.shared.recentRecords(limit: 100)
        await MainActor.run {
            recentHistoryByRule = Dictionary(grouping: records, by: \.ruleID)
        }
    }

    private func triggerDescription(_ rule: AutomationRule) -> String {
        let value = rule.threshold.formatted()
        switch rule.triggerType {
        case "cost_gt":
            return "Cost > \(value)"
        case "tokens_gt":
            return "Tokens > \(value)"
        default:
            return rule.triggerType
        }
    }

    private func actionDescription(_ rule: AutomationRule) -> String {
        guard let action = AutomationPresetAction(rawValue: rule.actionKind) else {
            return rule.actionKind
        }
        return action.displayName
    }

    private func scopeDescription(_ rule: AutomationRule) -> String {
        var parts: [String] = []
        if rule.accountIDs.isEmpty {
            parts.append("accounts: all active")
        } else {
            let names = activeAccounts
                .filter { rule.accountIDs.contains($0.id) }
                .map { $0.displayLabel(among: activeAccounts) }
            parts.append("accounts: \(names.isEmpty ? "\(rule.accountIDs.count) saved" : names.joined(separator: ", "))")
        }
        if !rule.groupLabels.isEmpty {
            parts.append("groups: \(rule.groupLabels.joined(separator: ", "))")
        }
        return "Scope: \(parts.joined(separator: " • "))"
    }
}

struct AddAutomationSheet: View {
    var accounts: [Account]
    var onSave: (AutomationRule) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var triggerType = "cost_gt"
    @State private var threshold = ""
    @State private var actionKind: AutomationPresetAction = .shell
    @State private var shellCommand = ""
    @State private var scopedAccountIDs: Set<UUID> = []
    @State private var scopedGroupLabels: Set<String> = []
    @State private var testOutput = ""
    @State private var commandError: String?

    private var groupLabels: [String] {
        Array(Set(accounts.compactMap(\.trimmedGroupLabel))).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New Automation").font(.headline)
            TextField("Name", text: $name)
            Picker("Trigger", selection: $triggerType) {
                Text("Cost >").tag("cost_gt")
                Text("Tokens >").tag("tokens_gt")
            }
            .pickerStyle(.segmented)
            TextField("Threshold", text: $threshold)
            Picker("Action", selection: $actionKind) {
                ForEach(AutomationPresetAction.allCases, id: \.self) { action in
                    Text(action.displayName).tag(action)
                }
            }
            if actionKind.isShell {
                TextField("Shell command", text: $shellCommand)
                    .onChange(of: shellCommand) { command in
                        commandError = AutomationEngine.validateCommand(command)
                    }
                if let commandError {
                    Text(commandError).foregroundColor(.red).font(.caption)
                }
            } else {
                Text("Native action: \(actionKind.displayName)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            if !accounts.isEmpty {
                DisclosureGroup("Account Scope") {
                    Text("Leave all unchecked to apply to all active accounts.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    ForEach(accounts) { account in
                        Toggle(account.displayLabel(among: accounts), isOn: Binding(
                            get: { scopedAccountIDs.contains(account.id) },
                            set: { enabled in
                                if enabled {
                                    scopedAccountIDs.insert(account.id)
                                } else {
                                    scopedAccountIDs.remove(account.id)
                                }
                            }
                        ))
                        .font(.caption)
                    }
                }
            }
            if !groupLabels.isEmpty {
                DisclosureGroup("Group Scope") {
                    Text("Optional additional group filter. Rules only fire for accounts whose group matches one of these labels.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    ForEach(groupLabels, id: \.self) { groupLabel in
                        Toggle(groupLabel, isOn: Binding(
                            get: { scopedGroupLabels.contains(groupLabel) },
                            set: { enabled in
                                if enabled {
                                    scopedGroupLabels.insert(groupLabel)
                                } else {
                                    scopedGroupLabels.remove(groupLabel)
                                }
                            }
                        ))
                        .font(.caption)
                    }
                }
            }
            if !testOutput.isEmpty {
                ScrollView {
                    Text(testOutput)
                        .font(.system(.caption, design: .monospaced))
                }
                .frame(height: 72)
                .border(Color.gray)
            }
            HStack {
                Button("Run Now (test)") {
                    guard let rule = buildRule() else { return }
                    Task {
                        let output = await AutomationEngine.testRun(rule: rule)
                        await MainActor.run { testOutput = output }
                    }
                }
                .disabled(buildRule() == nil)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") {
                    guard let rule = buildRule() else { return }
                    onSave(rule)
                    dismiss()
                }
                .disabled(buildRule() == nil)
            }
        }
        .padding()
        .frame(width: 440)
        .onChange(of: actionKind) { newValue in
            if !newValue.isShell {
                commandError = nil
            } else {
                commandError = AutomationEngine.validateCommand(shellCommand)
            }
        }
    }

    private func buildRule() -> AutomationRule? {
        guard let thresholdValue = Double(threshold),
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        let groupLabels = Array(scopedGroupLabels).sorted()
        if actionKind.isShell {
            let trimmedCommand = shellCommand.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedCommand.isEmpty, commandError == nil else { return nil }
            return AutomationRule(
                name: name,
                triggerType: triggerType,
                threshold: thresholdValue,
                shellCommand: trimmedCommand,
                actionKind: actionKind.rawValue,
                actionPayload: trimmedCommand,
                accountIDs: Array(scopedAccountIDs).sorted { $0.uuidString < $1.uuidString },
                groupLabels: groupLabels
            )
        }
        return AutomationRule(
            name: name,
            triggerType: triggerType,
            threshold: thresholdValue,
            shellCommand: "",
            actionKind: actionKind.rawValue,
            actionPayload: nil,
            accountIDs: Array(scopedAccountIDs).sorted { $0.uuidString < $1.uuidString },
            groupLabels: groupLabels
        )
    }
}
