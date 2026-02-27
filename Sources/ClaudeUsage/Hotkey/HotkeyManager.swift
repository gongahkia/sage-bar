import AppKit

class HotkeyManager {
    static let shared = HotkeyManager()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var currentConfig: GlobalHotkeyConfig?

    private init() {}

    func register(config: GlobalHotkeyConfig) {
        guard config.enabled else { unregister(); return }
        guard AXIsProcessTrusted() else {
            ErrorLogger.shared.log("Accessibility permission not granted — hotkey disabled", level: "WARN")
            NotificationCenter.default.post(name: .hotkeyAccessibilityRequired, object: nil)
            return
        }
        unregister()
        currentConfig = config
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, info -> Unmanaged<CGEvent>? in
                guard let p = info, type == .keyDown else { return Unmanaged.passRetained(event) }
                let mgr = Unmanaged<HotkeyManager>.fromOpaque(p).takeUnretainedValue()
                if mgr.matches(event: event) {
                    DispatchQueue.main.async { MenuBarManager.shared.togglePopover() }
                }
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
        eventTap = tap
        runLoopSource = src
    }

    func unregister() {
        if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let src = runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        eventTap = nil; runLoopSource = nil; currentConfig = nil
    }

    private func matches(event: CGEvent) -> Bool {
        guard let cfg = currentConfig else { return false }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        guard keyCode == Int64(keyCodeFor(key: cfg.key)) else { return false }
        let flags = event.flags
        let wantCmd = cfg.modifiers.contains("command")
        let wantOpt = cfg.modifiers.contains("option")
        let wantShift = cfg.modifiers.contains("shift")
        let wantCtrl = cfg.modifiers.contains("control")
        return flags.contains(.maskCommand) == wantCmd
            && flags.contains(.maskAlternate) == wantOpt
            && flags.contains(.maskShift) == wantShift
            && flags.contains(.maskControl) == wantCtrl
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
