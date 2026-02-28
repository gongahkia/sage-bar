import AppKit

// MARK: – HotkeyBinding

struct HotkeyBinding {
    let id: String
    let keyCode: CGKeyCode         // for regular: the trigger key; for chord: the second key
    let modifiers: CGEventFlags
    let chordFirstKeyCode: CGKeyCode? // set for chord bindings; nil for regular
    let handler: () -> Void

    init(id: String, keyCode: CGKeyCode, modifiers: CGEventFlags, handler: @escaping () -> Void) {
        self.id = id; self.keyCode = keyCode; self.modifiers = modifiers
        self.chordFirstKeyCode = nil; self.handler = handler
    }

    init(id: String, firstKeyCode: CGKeyCode, secondKeyCode: CGKeyCode, modifiers: CGEventFlags, handler: @escaping () -> Void) {
        self.id = id; self.keyCode = secondKeyCode; self.modifiers = modifiers
        self.chordFirstKeyCode = firstKeyCode; self.handler = handler
    }
}

// MARK: – HotkeyManager

class HotkeyManager {
    static let shared = HotkeyManager()
    var bindings: [HotkeyBinding] = []
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var lastKeyEvent: (keyCode: CGKeyCode, timestamp: TimeInterval)?

    private init() {}

    func register(binding: HotkeyBinding) {
        bindings.removeAll { $0.id == binding.id }
        bindings.append(binding)
        ensureTapRunning()
    }

    func unregister(id: String) {
        bindings.removeAll { $0.id == id }
        if bindings.isEmpty { stopTap() }
    }

    func unregisterAll() {
        bindings.removeAll()
        stopTap()
    }

    // convenience: register from GlobalHotkeyConfig
    func register(config: GlobalHotkeyConfig) {
        guard config.enabled else { unregisterAll(); return }
        guard AXIsProcessTrusted() else {
            ErrorLogger.shared.log("Accessibility permission not granted — hotkey disabled", level: "WARN")
            NotificationCenter.default.post(name: .hotkeyAccessibilityRequired, object: nil)
            return
        }
        let keyCode = CGKeyCode(keyCodeFor(key: config.key))
        let mods = modifierFlags(from: config.modifiers)
        let binding = HotkeyBinding(id: "primary", keyCode: keyCode, modifiers: mods) {
            MenuBarManager.shared.togglePopover()
        }
        unregisterAll()
        register(binding: binding)
    }

    // MARK: – private

    private func ensureTapRunning() {
        guard eventTap == nil else { return }
        guard AXIsProcessTrusted() else { return }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, info -> Unmanaged<CGEvent>? in
                guard let p = info, type == .keyDown else { return Unmanaged.passRetained(event) }
                Unmanaged<HotkeyManager>.fromOpaque(p).takeUnretainedValue().handle(event: event)
                return Unmanaged.passRetained(event)
            },
            userInfo: selfPtr
        ) else {
            ErrorLogger.shared.log("CGEventTap creation failed — hotkey disabled")
            return
        }
        let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        eventTap = tap; runLoopSource = src
    }

    private func stopTap() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        eventTap = nil; runLoopSource = nil
    }

    private func handle(event: CGEvent) {
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        let now = Date().timeIntervalSinceReferenceDate
        // chord bindings: second key within 500ms of first key
        if let last = lastKeyEvent, now - last.timestamp < 0.5 {
            for binding in bindings where binding.chordFirstKeyCode != nil {
                if last.keyCode == binding.chordFirstKeyCode! && keyCode == binding.keyCode {
                    lastKeyEvent = nil
                    DispatchQueue.main.async { binding.handler() }
                    return
                }
            }
        }
        // regular bindings
        for binding in bindings where binding.chordFirstKeyCode == nil {
            if binding.keyCode == keyCode && flags.contains(binding.modifiers) {
                DispatchQueue.main.async { binding.handler() }
            }
        }
        lastKeyEvent = (keyCode: keyCode, timestamp: now)
    }

    private func modifierFlags(from modifiers: [String]) -> CGEventFlags {
        var flags = CGEventFlags()
        if modifiers.contains("command") { flags.insert(.maskCommand) }
        if modifiers.contains("option") { flags.insert(.maskAlternate) }
        if modifiers.contains("shift") { flags.insert(.maskShift) }
        if modifiers.contains("control") { flags.insert(.maskControl) }
        return flags
    }

    private func keyCodeFor(key: String) -> Int {
        let map: [String: Int] = [
            "a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,
            "b":11,"q":12,"w":13,"e":14,"r":15,"y":16,"t":17,"1":18,"2":19,
            "3":20,"4":21,"6":22,"5":23,"=":24,"9":25,"7":26,"-":27,"8":28,
            "0":29,"]":30,"o":31,"u":32,"[":33,"i":34,"p":35,"l":37,"j":38,
            "'":39,"k":40,";":41,"\\": 42,",":43,"/":44,"n":45,"m":46,".":47,
            "`":50,"space":49,
        ]
        return map[key.lowercased()] ?? 8
    }
}

extension Notification.Name {
    static let hotkeyAccessibilityRequired = Notification.Name("HotkeyAccessibilityRequired")
}
