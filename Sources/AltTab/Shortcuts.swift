import Foundation
import SwitchCore

/// Where the chords live between launches.
///
/// A pair of integers in `UserDefaults`, not a plist of dictionaries: a shortcut is a key code
/// and a bitfield, and anything richer would only be a shape to migrate later.
enum Shortcuts {

    private static let defaults = UserDefaults.standard

    static func current() -> [Binding: Shortcut] {
        Binding.allCases.reduce(into: [:]) { result, binding in
            result[binding] = stored(binding) ?? binding.fallback
        }
    }

    static func set(_ shortcut: Shortcut, for binding: Binding) {
        defaults.set(Int(shortcut.keyCode), forKey: "\(binding.rawValue).keyCode")
        defaults.set(Int(shortcut.modifiers.rawValue), forKey: "\(binding.rawValue).modifiers")
    }

    static func reset() {
        for binding in Binding.allCases {
            defaults.removeObject(forKey: "\(binding.rawValue).keyCode")
            defaults.removeObject(forKey: "\(binding.rawValue).modifiers")
        }
    }

    /// A key code of zero is "A", a real key — so presence has to be asked, not inferred from
    /// the value being non-zero.
    private static func stored(_ binding: Binding) -> Shortcut? {
        guard defaults.object(forKey: "\(binding.rawValue).keyCode") != nil else { return nil }
        let keyCode = UInt16(defaults.integer(forKey: "\(binding.rawValue).keyCode"))
        let modifiers = Modifiers(rawValue: UInt8(defaults.integer(forKey: "\(binding.rawValue).modifiers")))
        let shortcut = Shortcut(keyCode: keyCode, modifiers: modifiers)
        // Anything unusable is treated as absent rather than honoured: a stored chord with no
        // hold modifier would leave the switcher openable and impossible to commit.
        return shortcut.isValid ? shortcut : nil
    }
}
