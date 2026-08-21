import AppKit

/// Everything the settings window can change, and where it lives between launches.
///
/// Read at the point of use rather than cached anywhere, so a change takes effect on the next
/// ⌥Tab without anything having to be told about it. The one exception is the menu bar icon,
/// which is a live object and so is created and destroyed by hand.
@MainActor
enum Settings {

    private static let defaults = UserDefaults.standard

    /// `bool(forKey:)` cannot tell "false" from "never set", and every flag here has a default
    /// that is not false for at least one of them — so presence is asked rather than inferred.
    private static func flag(_ key: String, or fallback: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }

    /// Off by default: the app is meant to be invisible. The icon is for someone who wants to
    /// see that it is running, and it is reached by opening the app.
    static var showsMenuBarIcon: Bool {
        get { flag("menuBarIcon", or: false) }
        set { defaults.set(newValue, forKey: "menuBarIcon") }
    }

    static var showsMinimized: Bool {
        get { flag("showMinimized", or: true) }
        set { defaults.set(newValue, forKey: "showMinimized") }
    }

    static var showsHiddenApps: Bool {
        get { flag("showHiddenApps", or: true) }
        set { defaults.set(newValue, forKey: "showHiddenApps") }
    }

    static var showsCloseButton: Bool {
        get { flag("showCloseButton", or: true) }
        set { defaults.set(newValue, forKey: "showCloseButton") }
    }

    /// How long a ⌥Tab has to be held before the panel appears at all, so that a switch made
    /// faster than this draws nothing. Zero is allowed and means "always show it".
    static var revealDelay: Double {
        get { defaults.object(forKey: "revealDelay") == nil ? 0.1 : defaults.double(forKey: "revealDelay") }
        set { defaults.set(max(0, min(0.5, newValue)), forKey: "revealDelay") }
    }

    static func reset() {
        for key in ["menuBarIcon", "showMinimized", "showHiddenApps", "showCloseButton", "revealDelay"] {
            defaults.removeObject(forKey: key)
        }
    }
}

/// The LaunchAgent that starts alt-tab at login.
///
/// The same job `install.sh` writes, written again here because a checkbox that only reports
/// the state of a file someone else wrote is a checkbox that cannot be unticked. The two must
/// stay in step; the plist below is the copy that matters, since this is the one that runs when
/// the box is ticked again.
@MainActor
enum LoginItem {

    static let label = "com.mr.alttab"

    private static var path: String {
        NSHomeDirectory() + "/Library/LaunchAgents/\(label).plist"
    }

    static var isEnabled: Bool { FileManager.default.fileExists(atPath: path) }

    /// True when it took. Reported rather than assumed: `launchctl` is the only thing that
    /// knows, and a checkbox that ticks itself on a failed bootstrap is worse than none.
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        guard enabled else {
            launchctl(["bootout", "gui/\(getuid())/\(label)"])
            try? FileManager.default.removeItem(atPath: path)
            return !isEnabled
        }
        guard let executable = Bundle.main.executablePath else { return false }
        let logs = NSHomeDirectory() + "/Library/Logs"
        try? FileManager.default.createDirectory(atPath: NSHomeDirectory() + "/Library/LaunchAgents",
                                                 withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: logs, withIntermediateDirectories: true)

        let job: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable, "--agent"],
            "RunAtLoad": true,
            // Restarted when it dies unexpectedly, left alone when it exits on purpose — which
            // is what it does when another copy already holds the single-instance lock, and what
            // Quit relies on. Plain KeepAlive would fight both.
            "KeepAlive": ["SuccessfulExit": false],
            // Without this, System Settings lists the login item under the developer's name
            // instead of the app's.
            "AssociatedBundleIdentifiers": [label],
            // Interactive, not Background: launchd throttles CPU and I/O for background agents,
            // and this one has to paint a window between a key going down and the same key
            // coming back up.
            "ProcessType": "Interactive",
            "LegacyTimers": true,
            // Not /tmp: that is world-readable, and anything this process ever prints came from
            // a keyboard path.
            "StandardErrorPath": logs + "/alt-tab.log",
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: job,
                                                             format: .xml, options: 0),
              (try? data.write(to: URL(fileURLWithPath: path))) != nil else { return false }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)

        launchctl(["bootout", "gui/\(getuid())/\(label)"])
        return launchctl(["bootstrap", "gui/\(getuid())", path])
    }

    @discardableResult
    private static func launchctl(_ arguments: [String]) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = arguments
        task.standardError = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return false }
        task.waitUntilExit()
        return task.terminationStatus == 0
    }
}
