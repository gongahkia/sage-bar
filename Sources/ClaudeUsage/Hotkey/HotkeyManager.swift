import AppKit
import Carbon.HIToolbox

class HotkeyManager {
    static let shared = HotkeyManager()
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var currentConfig: GlobalHotkeyConfig?

    private init() {}

    func register(config: GlobalHotkeyConfig) {
        guard config.enabled else { unregister(); return }
        unregister()
        currentConfig = config
        let keyCode = UInt32(keyCodeFor(key: config.key))
        var mods: UInt32 = 0
        if config.modifiers.contains("command") { mods |= UInt32(cmdKey) }
        if config.modifiers.contains("option")  { mods |= UInt32(optionKey) }
        if config.modifiers.contains("shift")   { mods |= UInt32(shiftKey) }
        if config.modifiers.contains("control") { mods |= UInt32(controlKey) }

        var gid = EventHotKeyID(signature: OSType(0x434C5548), id: 1) // 'CLUH'
        RegisterEventHotKey(keyCode, mods, gid, GetApplicationEventTarget(), 0, &hotKeyRef)

        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ -> OSStatus in
            DispatchQueue.main.async { MenuBarManager.shared.togglePopover() }
            return noErr
        }, 1, &eventSpec, nil, &handlerRef)
    }

    func unregister() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        hotKeyRef = nil
        currentConfig = nil
    }

    private func keyCodeFor(key: String) -> Int {
        // basic ASCII key → macOS virtual keycode mapping
        let map: [String: Int] = [
            "a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,
            "b":11,"q":12,"w":13,"e":14,"r":15,"y":16,"t":17,"1":18,"2":19,
            "3":20,"4":21,"6":22,"5":23,"=":24,"9":25,"7":26,"-":27,"8":28,
            "0":29,"]":30,"o":31,"u":32,"[":33,"i":34,"p":35,"l":37,"j":38,
            "'":39,"k":40,";":41,"\\": 42,",":43,"/":44,"n":45,"m":46,".":47,
            "`":50,"space":49,
        ]
        return map[key.lowercased()] ?? 8 // default "c"
    }
}
