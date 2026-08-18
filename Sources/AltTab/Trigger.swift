import AppKit
import Carbon.HIToolbox
import SwitchCore

// The Carbon callback is a C function pointer and so may capture nothing — not even an
// actor-isolated static — which is why these are plain globals.
private nonisolated(unsafe) var emit: ((SwitchCommand) -> Void)?
private nonisolated(unsafe) var commandForID: [UInt32: SwitchCommand] = [:]

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
/// and cannot tell the first Tab from the third, so rebinding ⌥ to ⌘ is a number in a table.
@MainActor
enum Trigger {

    private static var refs: [EventHotKeyRef?] = []
    private static var handler: EventHandlerRef?
    private static var monitor: Any?

    /// Which modifier, once released, means "go". Read from whatever `next` is currently bound
    /// to, so rebinding the chord rebinds the release along with it.
    private static var holdModifier: NSEvent.ModifierFlags = .option

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
            guard let command = commandForID[id.id] else { return noErr }
            DispatchQueue.main.async { emit?(command) }
            return noErr
        }, 1, &spec, nil, &handler)
        guard installed == noErr else { return false }

        // Commit is the hold modifier coming back up. A local monitor sees it because the panel
        // is key; it needs no grant, and returning the event leaves normal typing untouched.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            // Cleaned before comparing: local monitors emit bits nobody asked for, including
            // the function-key bit, and a raw equality test against them never matches.
            let held = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if !held.contains(holdModifier) { emit?(.commit) }
            return event
        }

        return apply(Shortcuts.current())
    }

    /// Registers a set of chords, replacing whatever was registered before.
    ///
    /// Carbon hands a chord to the first claimant, so re-binding means genuinely giving the old
    /// one back — an unregister that is skipped shows up as a shortcut that still works after
    /// the user changed it.
    @discardableResult
    static func apply(_ shortcuts: [Binding: Shortcut]) -> Bool {
        suspend()

        let commands: [Binding: SwitchCommand] = [.next: .next, .previous: .previous, .cancel: .cancel]
        var ok = true
        for (index, binding) in Binding.allCases.enumerated() {
            guard let shortcut = shortcuts[binding], shortcut.isValid else { continue }
            let id = UInt32(index + 1)
            var ref: EventHotKeyRef?
            let registered = RegisterEventHotKey(UInt32(shortcut.keyCode),
                                                 carbonModifiers(shortcut.modifiers),
                                                 EventHotKeyID(signature: OSType(0x4154_4221), id: id),  // 'ATB!'
                                                 GetEventDispatcherTarget(), 0, &ref)
            guard registered == noErr else { ok = false; continue }
            commandForID[id] = commands[binding]
            refs.append(ref)
        }

        if let next = shortcuts[.next], let hold = next.holdModifier {
            holdModifier = appKitModifier(hold)
        }
        return ok
    }

    /// Hands every chord back to the system.
    ///
    /// Used while recording a new one: without it, pressing the chord being replaced fires the
    /// switcher instead of being recorded, and the panel opens over the window asking for it.
    static func suspend() {
        for ref in refs where ref != nil { UnregisterEventHotKey(ref) }
        refs.removeAll()
        commandForID.removeAll()
    }

    private static func carbonModifiers(_ modifiers: Modifiers) -> UInt32 {
        var carbon: Int = 0
        if modifiers.contains(.command) { carbon |= cmdKey }
        if modifiers.contains(.option)  { carbon |= optionKey }
        if modifiers.contains(.shift)   { carbon |= shiftKey }
        if modifiers.contains(.control) { carbon |= controlKey }
        return UInt32(carbon)
    }

    private static func appKitModifier(_ modifier: Modifiers) -> NSEvent.ModifierFlags {
        switch modifier {
        case .command: return .command
        case .control: return .control
        default: return .option
        }
    }
}
