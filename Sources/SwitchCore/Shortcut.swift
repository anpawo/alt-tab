/// The modifiers a shortcut can carry. Our own set rather than `NSEvent.ModifierFlags`, so this
/// file stays free of AppKit — and because the flags AppKit hands out carry bits we never want
/// to compare against (a local monitor emits the function-key bit and worse).
public struct Modifiers: OptionSet, Equatable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let control = Modifiers(rawValue: 1 << 0)
    public static let option  = Modifiers(rawValue: 1 << 1)
    public static let shift   = Modifiers(rawValue: 1 << 2)
    public static let command = Modifiers(rawValue: 1 << 3)
}

/// One chord.
///
/// `keyCode` is an ANSI virtual key code — the physical position of the key, not the letter
/// printed on it, which is why the labels below are a table and not a keyboard lookup: on an
/// AZERTY keyboard the key at position 12 still reports 12, and calling it "Q" is what every
/// shortcut UI on macOS does.
public struct Shortcut: Equatable, Hashable {
    public let keyCode: UInt16
    public let modifiers: Modifiers

    public init(keyCode: UInt16, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// The modifier whose release commits the switch.
    ///
    /// Shift is never it: shift is how you say "the other way", so a chord that held it would
    /// commit the moment you reversed direction.
    public var holdModifier: Modifiers? {
        for candidate in [Modifiers.command, .option, .control] where modifiers.contains(candidate) {
            return candidate
        }
        return nil
    }

    /// A chord with no holdable modifier is refused, and not only because there would be
    /// nothing to release: these are registered as *global* hotkeys, so accepting a bare key
    /// would take that key away from every application on the machine.
    public var isValid: Bool { holdModifier != nil }

    /// ⌘Tab, ⌘⇧Tab and ⌘` are consumed by the Dock before any application-level hotkey is
    /// consulted. Registering one succeeds — it returns no error — and then never fires, which
    /// is the worst failure shape available: it reads as our own bug. Detected so it can be
    /// refused with an explanation instead.
    public var isClaimedByMacOS: Bool {
        let withoutShift = modifiers.subtracting(.shift)
        guard withoutShift == .command else { return false }
        return keyCode == 48 || keyCode == 50    // Tab, `
    }

    /// Apple's canonical order: ⌃⌥⇧⌘, then the key.
    public var label: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option)  { text += "⌥" }
        if modifiers.contains(.shift)   { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + (Self.keyNames[keyCode] ?? "key \(keyCode)")
    }

    static let keyNames: [UInt16: String] = [
        48: "Tab", 53: "Esc", 49: "Space", 36: "Return", 51: "Delete",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I",
        38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P", 12: "Q",
        15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
        50: "`", 27: "-", 24: "=", 33: "[", 30: "]", 42: "\\", 41: ";", 39: "'",
        43: ",", 47: ".", 44: "/",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]
}

/// The three things a shortcut can be bound to. `previous` is expected to be the `next` chord
/// plus shift, but nothing enforces that — binding them to unrelated keys works.
public enum Binding: String, CaseIterable {
    case next
    case previous
    case cancel

    public var title: String {
        switch self {
        case .next: return "Switch windows"
        case .previous: return "Go backwards"
        case .cancel: return "Cancel"
        }
    }

    public var fallback: Shortcut {
        switch self {
        case .next: return Shortcut(keyCode: 48, modifiers: .option)             // ⌥Tab
        case .previous: return Shortcut(keyCode: 48, modifiers: [.option, .shift]) // ⇧⌥Tab
        case .cancel: return Shortcut(keyCode: 53, modifiers: .option)            // ⌥Esc
        }
    }
}
