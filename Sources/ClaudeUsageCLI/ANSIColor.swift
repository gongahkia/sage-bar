import Foundation

enum ANSIColor: Int {
    case black = 30, red, green, yellow, blue, magenta, cyan, white
    case brightBlack = 90, brightRed, brightGreen, brightYellow, brightBlue, brightMagenta, brightCyan, brightWhite
    case reset = 0

    static func escape(code: Int) -> String { "\u{1B}[\(code)m" }
    var on: String { ANSIColor.escape(code: rawValue) }
    static var off: String { ANSIColor.escape(code: 0) }
}
