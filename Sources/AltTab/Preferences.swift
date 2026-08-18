import AppKit
import SwitchCore

/// Rebinding the chords.
///
/// A recorder rather than a list of presets: the point of building your own switcher is that it
/// does what you asked, and "⌥Tab or nothing" is not that.
///
/// The whole window exists in the recording state or out of it, which is why the global hotkeys
/// are handed back for the duration — otherwise pressing the chord you are trying to replace
/// opens the switcher over the window asking for it.
@MainActor
final class PreferencesWindow: NSObject, NSWindowDelegate {

    static let shared = PreferencesWindow()

    private var window: NSWindow?
    private var buttons: [Binding: NSButton] = [:]
    private var status = NSTextField(labelWithString: "")
    private var recording: Binding?
    private var monitor: Any?

    private static let hint = "Click a shortcut, then press the new one."

    func show() {
        let window = built()
        refresh()
        // A titled window on an .accessory app leaves the menu bar half-owned: we come to the
        // front without having a menu bar to put there, so the previous application's stays
        // drawn under ours. Becoming a regular app for as long as the window is open is the
        // ordinary remedy — it costs a Dock icon while the settings are up, and nothing after.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func built() -> NSWindow {
        if let window { return window }

        let width: CGFloat = 430
        // Derived from the number of bindings rather than fixed, so adding one is a case in the
        // enum and not a second set of coordinates to keep in step.
        let height = 112 + CGFloat(Binding.allCases.count) * 38
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "alt-tab"
        window.isReleasedWhenClosed = false
        window.delegate = self

        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        var y: CGFloat = height - 54
        for binding in Binding.allCases {
            let label = NSTextField(labelWithString: binding.title)
            label.frame = NSRect(x: 24, y: y + 4, width: 180, height: 18)
            content.addSubview(label)

            let button = NSButton(title: "", target: self, action: #selector(record(_:)))
            button.bezelStyle = .rounded
            button.frame = NSRect(x: 214, y: y, width: 190, height: 26)
            button.tag = Binding.allCases.firstIndex(of: binding) ?? 0
            content.addSubview(button)
            buttons[binding] = button

            y -= 38
        }

        status.frame = NSRect(x: 24, y: 48, width: width - 48, height: 34)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 2
        status.lineBreakMode = .byWordWrapping
        content.addSubview(status)

        let reset = NSButton(title: "Restore Defaults", target: self, action: #selector(resetAll))
        reset.bezelStyle = .rounded
        reset.frame = NSRect(x: width - 24 - 150, y: 12, width: 150, height: 26)
        content.addSubview(reset)

        window.contentView = content
        self.window = window
        return window
    }

    private func refresh() {
        let shortcuts = Shortcuts.current()
        for (binding, button) in buttons {
            button.title = recording == binding ? "Press a shortcut…" : (shortcuts[binding]?.label ?? "—")
        }
        if recording == nil { status.stringValue = Self.hint }
    }

    // MARK: - Recording

    @objc private func record(_ sender: NSButton) {
        let binding = Binding.allCases[sender.tag]
        guard recording != binding else { return stopRecording() }

        recording = binding
        status.stringValue = "Press the shortcut for “\(binding.title)”, or Esc to keep the current one."
        // Every chord goes back to the system for the duration, so the one being replaced can
        // be pressed without firing.
        Trigger.suspend()
        refresh()

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.captured(event, for: binding)
            return nil          // swallowed: this keystroke is an answer, not typing
        }
    }

    private func captured(_ event: NSEvent, for binding: Binding) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: Modifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option)  { modifiers.insert(.option) }
        if flags.contains(.shift)   { modifiers.insert(.shift) }
        if flags.contains(.control) { modifiers.insert(.control) }

        // A bare Escape is how you back out — which is why it cannot also be a shortcut on its
        // own, and does not need to be: ⌥Esc is.
        if event.keyCode == 53 && modifiers.isEmpty {
            stopRecording()
            return
        }

        let shortcut = Shortcut(keyCode: event.keyCode, modifiers: modifiers)

        guard shortcut.isValid else {
            status.stringValue = "\(shortcut.label) has nothing to hold. Add ⌘, ⌥ or ⌃ — the "
                + "switch happens when you let the modifier go, and a shortcut with none would "
                + "take that key from every app."
            return
        }
        guard !shortcut.isClaimedByMacOS else {
            status.stringValue = "macOS keeps \(shortcut.label) for its own switcher and never "
                + "passes it on. Taking it means switching the system one off, which outlives "
                + "this app — so it is not offered here."
            return
        }

        Shortcuts.set(shortcut, for: binding)
        stopRecording()
        status.stringValue = "\(binding.title) is now \(shortcut.label)."
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = nil
        // Re-registering is what actually rebinds; without it the new chord is only saved.
        if !Trigger.apply(Shortcuts.current()) {
            status.stringValue = "Another application already owns that shortcut, so it could "
                + "not be registered. Pick a different one."
        }
        refresh()
    }

    @objc private func resetAll() {
        Shortcuts.reset()
        stopRecording()
        status.stringValue = "Back to ⌥Tab, ⇧⌥Tab and ⌥Esc."
    }

    /// Closing mid-recording must still give the hotkeys back, or the switcher stays dead until
    /// the next launch.
    func windowWillClose(_ notification: Notification) {
        if recording != nil { stopRecording() }
        NSApp.setActivationPolicy(.accessory)
    }
}
