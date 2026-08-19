import AppKit
import SwitchCore

/// The system's own ⌘Tab, and how to give it back.
///
/// alt-tab does not take ⌘Tab: it binds ⌥Tab, which is unclaimed, so nothing here is called on
/// the normal path. It ships anyway because the *recovery* half is the valuable half —
/// disabling the system chord is a setting that outlives the process that set it, so any app
/// that takes ⌘Tab and then crashes leaves the machine with no switcher at all, across
/// reboots, with no UI anywhere to explain it.
///
/// Deliberately not called at launch. The design note that asked for an unconditional restore
/// assumed alt-tab would be the app disabling it; while ⌘Tab is somebody else's — AltTab is
/// installed on this machine and holds it disabled right now — restoring on every launch would
/// break a working switcher instead of repairing a broken one. `--restore-hotkeys` is the
/// escape hatch, and it works without a GUI.
enum SymbolicHotKeys {
    private typealias SetEnabled = @convention(c) (Int32, Bool) -> Int32

    static func restoreSystemSwitcher() {
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY),
              let symbol = dlsym(handle, "CGSSetSymbolicHotKeyEnabled") else {
            FileHandle.standardError.write(Data("alt-tab: CGSSetSymbolicHotKeyEnabled is gone on this macOS\n".utf8))
            return
        }
        let setEnabled = unsafeBitCast(symbol, to: SetEnabled.self)
        // 1 ⌘Tab · 2 ⌘⇧Tab · 6 ⌘` — collected, not picked: the pick used to come from
        // iterating a dictionary, whose order is not stable across launches, so which chord got
        // restored varied per run.
        for id: Int32 in [1, 2, 6] { _ = setEnabled(id, true) }
    }
}

let arguments = Set(CommandLine.arguments.dropFirst())

if arguments.contains("--restore-hotkeys") {
    SymbolicHotKeys.restoreSystemSwitcher()
    exit(0)
}

if arguments.contains("--render") {
    MainActor.assumeIsolated {
        WindowList.prewarm()
        for (i, window) in WindowList.snapshot().enumerated() {
            let handle = window.element == nil ? "no element" : "ok"
            print("\(i)  \(window.appName) — \(window.title)  [wid \(window.id), \(handle)]")
        }
    }
    exit(0)
}

let application = NSApplication.shared
// No Dock icon and no menu bar. Also what keeps alt-tab out of the window ordering it switches.
application.setActivationPolicy(.accessory)

var state = SwitcherState()
var windows: [WindowInfo] = []
// Held for the process lifetime: an NSStatusItem lives exactly as long as whatever owns it.
var statusItem: StatusItemController?

/// The only place both worlds meet. Everything above is AppKit, everything below is a value
/// type that cannot import it, and nothing calls back up.
@MainActor
func dispatch(_ command: SwitchCommand) {
    if !state.isOpen, command == .next {
        // Enumerate on open, once, and hand the same array to every step of the session.
        // Re-reading it per keystroke would let the list move under the selection.
        windows = WindowList.snapshot()
        if !AXIsProcessTrusted() {
            Panel.note("No Accessibility grant — window names and switching are unavailable.")
        } else if !Thumbnails.isPermitted {
            // Said here rather than by putting a system prompt over a switcher the user is in
            // the middle of using. The menu bar item is where it can be granted.
            Panel.note("Showing icons — window pictures need Screen Recording, in the ⇥ menu.")
        } else {
            Panel.note(nil)
        }
    }

    guard let effect = state.handle(command, windows: windows) else { return }
    switch effect {
    case let .show(list, index):
        Panel.show(list, selected: index)
        Trigger.watchForRelease()
    case let .move(index):
        Panel.move(to: index)
    case .hide:
        Trigger.stopWatchingForRelease()
        Panel.hide()
    case let .raise(window):
        Trigger.stopWatchingForRelease()
        Panel.dismiss()
        if !Raise.perform(window) {
            // Hangs off the failed *action*, not off the permission check: the check can
            // report trusted after a revocation, and the failure to design against is the
            // panel that opens, looks perfect, and then does nothing when ⌥ comes up.
            Panel.note("Could not switch to \(window.appName) — check alt-tab in "
                       + "System Settings → Privacy & Security → Accessibility.")
        }
        // Photographed after the raise, and by id rather than by asking who has focus — asked
        // before, the answer is about the window we are leaving.
        Thumbnails.captureSoon(window.id)
    }
}

// Everything expensive, once, before the first keystroke: the window, its view tree, the icon
// cache, and one Accessibility connection per running app. Left lazy, the first ⌥Tab pays all
// of it at once and that is what "slow the first time" is.
// `assumeIsolated` rather than an await: this is main.swift, it is already on the main thread,
// and the alternative is an async entry point that defers setup past the first keystroke.
MainActor.assumeIsolated {
    Panel.warm()
    WindowList.prewarm()
    statusItem = StatusItemController()

    guard Trigger.install({ command in dispatch(command) }) else {
        FileHandle.standardError.write(Data("alt-tab: could not register ⌥Tab — another app owns it\n".utf8))
        exit(1)
    }

    // A window is photographed while it is the one in use. Cross-application switches are what
    // NSWorkspace reports; a switch between two windows of the same application is not, and is
    // covered instead by the capture that follows our own raise below.
    NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
    ) { note in
        MainActor.assumeIsolated {
            guard !state.isOpen,
                  let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            Thumbnails.captureFocused(of: app.processIdentifier)
        }
    }

    // One pass a few seconds after login, so the very first ⌥Tab of the day has pictures too
    // rather than being the one open that pays for all of them.
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
        MainActor.assumeIsolated { Thumbnails.captureQuietly(WindowList.snapshot().map(\.id)) }
    }

    if arguments.contains("--fake") {
        dispatch(.next)
    }
    // There is no Dock icon to click, so the menu bar is normally the only way in. This is the
    // other one, for when the menu bar is full.
    if arguments.contains("--settings") {
        PreferencesWindow.shared.show()
    }
}

application.run()
