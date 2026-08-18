import AppKit
import Carbon.HIToolbox
import SwitchCore

// The Carbon callback is a C function pointer and so may capture nothing — not even an
// actor-isolated static — which is why this is a plain global.
private nonisolated(unsafe) var emit: ((SwitchCommand) -> Void)?

/// Where key presses come from.
///
/// Carbon's `RegisterEventHotKey`, not an event tap and not `addGlobalMonitorForEvents`. Both
/// of those need Accessibility — a TCC prompt for a background agent with no window to explain
/// itself — while hotkey registration needs nothing at all, is the only mechanism that survives
/// Secure Input, and is the only one that *consumes* the chord so the app underneath never
/// sees a stray Tab.
///
/// The release is caught by a *local* monitor, which also costs nothing, and works because the
/// panel takes key focus while it is up.
///
/// Note the vocabulary this hands upwards: `.next`, never `.open`. The trigger holds no state
/// and cannot tell the first Tab from the third, so swapping ⌥ for ⌘ later is a keycode
/// change in this file and nothing more.
@MainActor
enum Trigger {

    private static var refs: [EventHotKeyRef?] = []
    private static var handler: EventHandlerRef?
    private static var monitor: Any?

    @discardableResult
    static func install(_ block: @escaping (SwitchCommand) -> Void) -> Bool {
        emit = block

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            let command: SwitchCommand
            switch id.id {
            case 1: command = .next
            case 2: command = .previous
            default: command = .cancel
            }
            DispatchQueue.main.async { emit?(command) }
            return noErr
        }, 1, &spec, nil, &handler)
        guard installed == noErr else { return false }

        // ⌥Tab, ⇧⌥Tab, ⌥Esc. Carbon fires once per physical press and ignores the OS auto-repeat,
        // so holding Tab down does not cycle — each step is its own tap. That is the behaviour
        // asked for; synthesising a repeat would mean reading the user's key-repeat settings and
        // gating every tick on the panel being painted.
        let chords: [(UInt32, UInt32, UInt32)] = [
            (UInt32(kVK_Tab), UInt32(optionKey), 1),
            (UInt32(kVK_Tab), UInt32(optionKey | shiftKey), 2),
            (UInt32(kVK_Escape), UInt32(optionKey), 3),
        ]
        for (key, modifiers, id) in chords {
            var ref: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: OSType(0x5441_434B), id: id)   // 'TACK'
            guard RegisterEventHotKey(key, modifiers, hotKeyID,
                                      GetEventDispatcherTarget(), 0, &ref) == noErr else {
                return false
            }
            refs.append(ref)
        }

        // Commit is ⌥ coming back up. A local monitor sees it because the panel is key; it
        // needs no grant, and returning the event leaves normal typing untouched.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            if !event.modifierFlags.contains(.option) { emit?(.commit) }
            return event
        }
        return true
    }
}
