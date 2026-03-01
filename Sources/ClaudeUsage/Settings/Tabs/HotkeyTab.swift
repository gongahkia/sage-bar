import SwiftUI

// MARK: – Hotkey Tab

struct HotkeyTab: View {
    @State private var config = ConfigManager.shared.load()
    @State private var hasAccessibility = AXIsProcessTrusted()

    var body: some View {
        Form {
            Toggle("Enable global hotkey", isOn: $config.hotkey.enabled)
            if !hasAccessibility {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Accessibility access required for global hotkey.")
                        .foregroundColor(.orange).font(.caption)
                    Button("Grant Accessibility Access…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                }
            }
            if config.hotkey.enabled {
                TextField("Key", text: $config.hotkey.key)
                MultiPicker(label: "Modifiers", options: ["command","option","shift","control"], selection: $config.hotkey.modifiers)
                Divider()
                Section("Hotkey Recorder") {
                    HotkeyRecorderControl(config: $config.hotkeyConfig)
                }
            }
        }
        .onAppear { hasAccessibility = AXIsProcessTrusted() }
        .onChange(of: config.hotkey) { _ in
            ConfigManager.shared.save(config)
            HotkeyManager.shared.register(config: config.hotkey)
        }
        .onChange(of: config.hotkeyConfig) { _ in ConfigManager.shared.save(config) }
        .padding()
    }
}

// MARK: – Hotkey Recorder

struct HotkeyRecorderControl: View {
    @Binding var config: HotkeyConfig
    @State private var isRecording = false
    @State private var pendingKeyCode: Int?
    @State private var pendingModifiers: [String] = []
    @State private var monitor: Any?

    private var bindingLabel: String {
        let mods = config.primaryModifiers.map {
            switch $0 {
            case "command": return "⌘"
            case "shift": return "⇧"
            case "option": return "⌥"
            case "control": return "⌃"
            default: return $0
            }
        }.joined()
        let keyName = keyName(for: config.primaryKeyCode)
        return "\(mods)\(keyName)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Binding:").foregroundColor(.secondary)
                Text(isRecording ? "Press a key…" : bindingLabel)
                    .fontWeight(.medium)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(isRecording ? Color.accentColor.opacity(0.15) : Color.secondary.opacity(0.1))
                    .cornerRadius(6)
                Spacer()
                Button(isRecording ? "Cancel" : "Record") {
                    if isRecording { stopRecording() } else { startRecording() }
                }
                if isRecording, let kc = pendingKeyCode {
                    Button("Confirm") {
                        config.primaryKeyCode = kc
                        config.primaryModifiers = pendingModifiers
                        stopRecording()
                        ConfigManager.shared.save(ConfigManager.shared.load())
                    }
                }
            }
            Toggle("Chord enabled", isOn: $config.chordEnabled)
        }
    }

    private func startRecording() {
        isRecording = true
        pendingKeyCode = nil; pendingModifiers = []
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            pendingKeyCode = Int(event.keyCode)
            var mods: [String] = []
            if event.modifierFlags.contains(.command) { mods.append("command") }
            if event.modifierFlags.contains(.shift) { mods.append("shift") }
            if event.modifierFlags.contains(.option) { mods.append("option") }
            if event.modifierFlags.contains(.control) { mods.append("control") }
            pendingModifiers = mods
            return nil // consume event
        }
    }

    private func stopRecording() {
        isRecording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    private func keyName(for keyCode: Int) -> String {
        let map: [Int: String] = [
            0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",
            11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",18:"1",19:"2",
            20:"3",21:"4",22:"6",23:"5",24:"=",25:"9",26:"7",27:"-",28:"8",
            29:"0",30:"]",31:"O",32:"U",33:"[",34:"I",35:"P",37:"L",38:"J",
            39:"'",40:"K",41:";",43:",",44:"/",45:"N",46:"M",47:".",49:"Space",
        ]
        return map[keyCode] ?? "?"
    }
}

struct MultiPicker: View {
    let label: String
    let options: [String]
    @Binding var selection: [String]
    var body: some View {
        VStack(alignment: .leading) {
            Text(label).font(.caption).foregroundColor(.secondary)
            HStack {
                ForEach(options, id: \.self) { opt in
                    Toggle(opt, isOn: Binding(
                        get: { selection.contains(opt) },
                        set: { v in if v { selection.append(opt) } else { selection.removeAll { $0 == opt } } }
                    )).toggleStyle(.checkbox)
                }
            }
        }
    }
}

