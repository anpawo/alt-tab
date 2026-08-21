import AppKit
import SwitchCore

/// The settings window, and the only face alt-tab has.
///
/// The app is invisible by design: no Dock icon, and no menu bar icon unless it is asked for.
/// So this window is where everything that cannot be said by a switcher lives — whether the
/// permissions it needs have been granted, what the chord is, and how to stop it. Opening the
/// application is what opens it; there is nowhere else to click.
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

    private var accessibilityLabel = NSTextField(labelWithString: "")
    private var accessibilityButton = NSButton()
    private var recordingLabel = NSTextField(labelWithString: "")
    private var recordingButton = NSButton()
    private var delaySlider = NSSlider()
    private var delayValue = NSTextField(labelWithString: "")
    private var menuBarBox = NSButton()
    private var loginBox = NSButton()
    private var minimizedBox = NSButton()
    private var hiddenBox = NSButton()
    private var crossBox = NSButton()

    private static let hint = "Click the shortcut, then press the new one."

    func show() {
        let window = built()
        refresh()
        // A titled window on an .accessory app leaves the menu bar half-owned: we come to the
        // front without having a menu bar to put there, so the previous application's stays
        // drawn under ours. Becoming a regular app for as long as the window is open is the
        // ordinary remedy — it costs a Dock icon while the settings are up, and nothing after.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        // Visible for as long as this window is: opening the application is the moment where
        // showing what is running costs nothing, and the icon carries the menu.
        MenuBar.setVisible(true)
    }

    // MARK: - Building

    private static let width: CGFloat = 460
    private static let margin: CGFloat = 24

    private func built() -> NSWindow {
        if let window { return window }

        let width = Self.width
        let height: CGFloat = 540
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                              styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = "alt-tab"
        window.isReleasedWhenClosed = false
        window.delegate = self

        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        let margin = Self.margin
        let full = width - margin * 2
        var y = height - 22

        func header(_ text: String) {
            y -= 17
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .secondaryLabelColor
            label.frame = NSRect(x: margin, y: y, width: full, height: 15)
            content.addSubview(label)
            y -= 6
        }

        /// One line of the permissions block: what the state is, and the button that changes it.
        func permission(_ title: String, _ state: NSTextField, _ button: NSButton,
                        action: Selector, buttonTitle: String) {
            y -= 26
            let label = NSTextField(labelWithString: title)
            label.frame = NSRect(x: margin, y: y + 4, width: 150, height: 18)
            content.addSubview(label)

            state.frame = NSRect(x: margin + 150, y: y + 4, width: 120, height: 18)
            state.font = .systemFont(ofSize: 11)
            state.textColor = .secondaryLabelColor
            content.addSubview(state)

            button.title = buttonTitle
            button.target = self
            button.action = action
            button.bezelStyle = .rounded
            button.frame = NSRect(x: width - margin - 140, y: y - 2, width: 140, height: 26)
            content.addSubview(button)
            y -= 8
        }

        func check(_ box: NSButton, _ title: String, action: Selector) {
            y -= 20
            box.setButtonType(.switch)
            box.title = title
            box.target = self
            box.action = action
            box.frame = NSRect(x: margin, y: y, width: full, height: 18)
            content.addSubview(box)
            y -= 6
        }

        header("Permissions")
        permission("Accessibility", accessibilityLabel, accessibilityButton,
                   action: #selector(openAccessibilitySettings), buttonTitle: "Open Settings…")
        permission("Screen Recording", recordingLabel, recordingButton,
                   action: #selector(requestScreenRecording), buttonTitle: "Allow…")
        y -= 44
        let note = NSTextField(labelWithString:
            "Accessibility is required: without it alt-tab can neither name a window nor raise "
            + "one. Screen Recording is not — without it the tiles show application icons "
            + "rather than pictures.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.maximumNumberOfLines = 3
        note.lineBreakMode = .byWordWrapping
        note.frame = NSRect(x: margin, y: y, width: full, height: 44)
        content.addSubview(note)
        y -= 12

        header("Shortcut")
        for binding in Binding.allCases {
            y -= 26
            let label = NSTextField(labelWithString: binding.title)
            label.frame = NSRect(x: margin, y: y + 4, width: 200, height: 18)
            content.addSubview(label)

            let button = NSButton(title: "", target: self, action: #selector(record(_:)))
            button.bezelStyle = .rounded
            button.frame = NSRect(x: width - margin - 190, y: y - 2, width: 190, height: 26)
            button.tag = Binding.allCases.firstIndex(of: binding) ?? 0
            content.addSubview(button)
            buttons[binding] = button
            y -= 8
        }
        y -= 10

        header("The panel")
        y -= 26
        let delayLabel = NSTextField(labelWithString: "Appears after")
        delayLabel.frame = NSRect(x: margin, y: y + 4, width: 130, height: 18)
        content.addSubview(delayLabel)
        delaySlider.minValue = 0
        delaySlider.maxValue = 0.5
        delaySlider.target = self
        delaySlider.action = #selector(delayChanged)
        delaySlider.frame = NSRect(x: margin + 130, y: y, width: full - 130 - 70, height: 22)
        content.addSubview(delaySlider)
        delayValue.frame = NSRect(x: width - margin - 66, y: y + 4, width: 66, height: 18)
        delayValue.alignment = .right
        delayValue.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        delayValue.textColor = .secondaryLabelColor
        content.addSubview(delayValue)
        y -= 10

        check(minimizedBox, "List minimized windows", action: #selector(toggleMinimized))
        check(hiddenBox, "List windows of hidden applications", action: #selector(toggleHidden))
        check(crossBox, "Show the close button on a tile under the pointer", action: #selector(toggleCross))
        y -= 12

        header("alt-tab itself")
        check(menuBarBox, "Keep the ⇥ icon in the menu bar after this window closes",
              action: #selector(toggleMenuBar))
        check(loginBox, "Start at login", action: #selector(toggleLogin))
        y -= 12

        y -= 34
        status.frame = NSRect(x: margin, y: y, width: full, height: 34)
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 2
        status.lineBreakMode = .byWordWrapping
        content.addSubview(status)

        let quit = NSButton(title: "Quit alt-tab", target: self, action: #selector(quit))
        quit.bezelStyle = .rounded
        quit.frame = NSRect(x: margin, y: 16, width: 120, height: 26)
        content.addSubview(quit)

        let reset = NSButton(title: "Restore Defaults", target: self, action: #selector(resetAll))
        reset.bezelStyle = .rounded
        reset.frame = NSRect(x: width - margin - 150, y: 16, width: 150, height: 26)
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

        let trusted = AXIsProcessTrusted()
        accessibilityLabel.stringValue = trusted ? "Granted" : "Not granted"
        accessibilityButton.title = trusted ? "Open Settings…" : "Grant…"
        let pictures = Thumbnails.isPermitted
        recordingLabel.stringValue = pictures ? "Granted" : "Not granted"
        recordingButton.isEnabled = !pictures

        delaySlider.doubleValue = Settings.revealDelay
        delayValue.stringValue = "\(Int((Settings.revealDelay * 1000).rounded())) ms"
        minimizedBox.state = Settings.showsMinimized ? .on : .off
        hiddenBox.state = Settings.showsHiddenApps ? .on : .off
        crossBox.state = Settings.showsCloseButton ? .on : .off
        menuBarBox.state = Settings.showsMenuBarIcon ? .on : .off
        loginBox.state = LoginItem.isEnabled ? .on : .off
    }

    // MARK: - Permissions

    @objc private func openAccessibilitySettings() {
        // The prompt first: it is the only thing that puts alt-tab in the list at all, and the
        // pane is useless while the app is not in it.
        WindowAction.trusted()
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    /// Both, because neither alone lands anywhere useful: the request puts the prompt up the
    /// first time and does nothing ever after, and the pane is the only route once it has been
    /// answered. The answer is latched for the life of the process either way, so this says so
    /// rather than pretending pictures will appear.
    @objc private func requestScreenRecording() {
        Thumbnails.requestAccess()
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
        status.stringValue = "macOS answers this once per launch, so window pictures start "
            + "appearing after alt-tab is quit and opened again."
    }

    // MARK: - Switches

    @objc private func delayChanged() {
        Settings.revealDelay = delaySlider.doubleValue
        delayValue.stringValue = "\(Int((Settings.revealDelay * 1000).rounded())) ms"
        status.stringValue = Settings.revealDelay == 0
            ? "The panel appears on every switch, however brief."
            : "A switch made faster than this draws nothing at all."
    }

    @objc private func toggleMinimized() {
        Settings.showsMinimized = minimizedBox.state == .on
    }

    @objc private func toggleHidden() {
        Settings.showsHiddenApps = hiddenBox.state == .on
    }

    @objc private func toggleCross() {
        Settings.showsCloseButton = crossBox.state == .on
    }

    @objc private func toggleMenuBar() {
        Settings.showsMenuBarIcon = menuBarBox.state == .on
        // Not hidden here: the icon belongs to this window while it is open, whichever way the
        // box is ticked. What the box decides is what happens when the window closes.
        status.stringValue = Settings.showsMenuBarIcon
            ? "The ⇥ icon stays in the menu bar."
            : "alt-tab goes invisible again when this window closes. Open the application to "
                + "come back here."
    }

    @objc private func toggleLogin() {
        let wanted = loginBox.state == .on
        let done = LoginItem.setEnabled(wanted)
        loginBox.state = LoginItem.isEnabled ? .on : .off
        if !done {
            status.stringValue = wanted
                ? "launchd refused the job, so alt-tab will not start at login."
                : "launchd refused to unload the job; it will still start at login."
            return
        }
        status.stringValue = wanted
            ? "alt-tab starts with the session, without appearing anywhere."
            : "alt-tab no longer starts at login. It keeps running until you quit it."
    }

    /// `NSApp.terminate` alone is not enough while the LaunchAgent is loaded: it has KeepAlive
    /// set, so launchd brings us straight back. Unloading the job stops that until the next
    /// login re-loads it — and the job is left on disk, so the login item survives a quit.
    @objc private func quit() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["bootout", "gui/\(getuid())/\(LoginItem.label)"]
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
        // Before going, not after: quitting while still holding ⌘Tab would leave the machine
        // with no switcher at all and nothing running to explain it.
        Trigger.releaseSystemChords()
        NSApp.terminate(nil)
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
        Shortcuts.set(shortcut, for: binding)
        stopRecording()
        // Said plainly rather than refused. The Dock consumes these before any application sees
        // them, so holding one means switching Apple's switcher off — which stays off until
        // something turns it back on. Quitting alt-tab and uninstalling both do.
        status.stringValue = shortcut.takesOverSystemChord
            ? "\(binding.title) is now \(shortcut.label), and macOS no longer answers it — "
                + "its own switcher is off for as long as alt-tab holds the chord."
            : "\(binding.title) is now \(shortcut.label)."
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
        Settings.reset()
        stopRecording()
        status.stringValue = "Back to ⌥Tab, and to every default on this page."
    }

    /// Closing mid-recording must still give the hotkeys back, or the switcher stays dead until
    /// the next launch.
    func windowWillClose(_ notification: Notification) {
        if recording != nil { stopRecording() }
        NSApp.setActivationPolicy(.accessory)
        MenuBar.setVisible(Settings.showsMenuBarIcon)
    }
}
