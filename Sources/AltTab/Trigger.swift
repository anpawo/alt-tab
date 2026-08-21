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
    private static var escape: Any?
    private static var release: Timer?

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

        // Escape backs out, without costing a global hotkey: the panel holds key focus while it
        // is up, so a local monitor is enough, and a chord registered system-wide would take a
        // key from every application for something reachable only in this half-second.
        escape = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Whatever is held with it. The panel is only ever key while a session is open, and
            // the modifier that opened it is by definition still down for most of that — an
            // Escape that insisted on being pressed alone was an Escape that never arrived.
            guard event.keyCode == 53 else { return event }
            emit?(.cancel)
            return nil
        }

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
        reconcileSystemChords(with: shortcuts)

        let commands: [Binding: SwitchCommand] = [.next: .next]
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

    /// Switches off the system chords the new bindings need, and gives back the ones they do
    /// not.
    ///
    /// This is the one thing alt-tab does that outlives it: a symbolic hot key stays off until
    /// something turns it back on. So the set is written down before it is acted on — a copy
    /// that dies here must leave a record of what it took, or the only way back is a flag on a
    /// binary the user no longer has a reason to keep.
    private static func reconcileSystemChords(with shortcuts: [Binding: Shortcut]) {
        let wanted = Set(shortcuts.values.flatMap(\.systemChords))
        let held = Set(Shortcuts.suppressedSystemChords)
        // Applied every time, not only when the set changed. What we wrote down is what we
        // asked for, not what is true: a login, a system update or another switcher can hand a
        // chord back without telling us, and a record that says we still hold it would then
        // stop us from ever taking it again.
        Shortcuts.suppressedSystemChords = Array(wanted).sorted()
        SymbolicHotKeys.set(Array(held.subtracting(wanted)).sorted(), enabled: true)
        SymbolicHotKeys.set(Array(wanted).sorted(), enabled: false)
    }

    /// Gives every system chord back, whatever we are holding. The deliberate exits go through
    /// here: quitting with ⌘Tab still switched off leaves a machine with no switcher at all.
    static func releaseSystemChords() {
        Shortcuts.suppressedSystemChords = []
        SymbolicHotKeys.restoreSystemSwitcher()
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

    /// Watches for the held modifier to come back up, by asking rather than by being told.
    ///
    /// The local monitor above is the fast path and cannot be the only one: it delivers events
    /// only while this app is active, activation is asynchronous, and the race is genuinely lost
    /// some of the time — measured, not feared. When it is lost nothing ever reports the release
    /// and the panel stays up for good, which is the one failure a switcher cannot have.
    ///
    /// `flagsState` is the live state of the keyboard, readable from a background process with
    /// no grant of any kind. Polling it costs a timer for the half-second the panel is up.
    static func watchForRelease() {
        release?.invalidate()
        release = Timer.scheduledTimer(withTimeInterval: 0.016, repeats: true) { _ in
            MainActor.assumeIsolated {
                let held = CGEventSource.flagsState(.combinedSessionState)
                guard !held.contains(carbonFlag(holdModifier)) else { return }
                stopWatchingForRelease()
                emit?(.commit)
            }
        }
        // Common mode, or the timer stops for as long as a menu or a scroll is being tracked —
        // which is exactly when a switch is most likely to be in flight.
        RunLoop.main.add(release!, forMode: .common)
    }

    static func stopWatchingForRelease() {
        release?.invalidate()
        release = nil
    }

    private static func carbonFlag(_ modifier: NSEvent.ModifierFlags) -> CGEventFlags {
        switch modifier {
        case .command: return .maskCommand
        case .control: return .maskControl
        default: return .maskAlternate
        }
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
