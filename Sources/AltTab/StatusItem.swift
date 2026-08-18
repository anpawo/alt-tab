import AppKit
import SwitchCore

/// The menu bar presence: a small Tab key.
///
/// This is the only place alt-tab is visible when the panel is down, so it is also the answer
/// to "is it running" — a background agent with no Dock icon and no window has nothing else to
/// say so with.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    override init() {
        super.init()
        item.button?.image = Self.tabKeyImage()
        item.button?.toolTip = "alt-tab"
        menu.delegate = self
        // Attached permanently rather than popped on demand: the whole of this item is its
        // menu, so a left click should open it.
        item.menu = menu
    }

    /// A key cap with a tab arrow in it, drawn rather than borrowed from SF Symbols: the symbol
    /// set has the arrow (`arrow.right.to.line`) but not the cap around it, and the cap is what
    /// makes it read as the Tab *key* instead of a generic direction.
    ///
    /// Template mode hands the menu bar control of the colour, so it inverts with the bar.
    private static func tabKeyImage() -> NSImage {
        let size = NSSize(width: 19, height: 14)
        let image = NSImage(size: size, flipped: false) { rect in
            let cap = NSBezierPath(roundedRect: rect.insetBy(dx: 0.8, dy: 0.8),
                                   xRadius: 3.2, yRadius: 3.2)
            cap.lineWidth = 1.2
            NSColor.black.setStroke()
            cap.stroke()

            let glyph = "⇥" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 9, weight: .semibold),
                .foregroundColor: NSColor.black,
            ]
            let glyphSize = glyph.size(withAttributes: attributes)
            glyph.draw(at: NSPoint(x: rect.midX - glyphSize.width / 2,
                                   y: rect.midY - glyphSize.height / 2 - 0.5),
                       withAttributes: attributes)
            return true
        }
        image.isTemplate = true
        return image
    }

    @objc private func openPreferences() {
        PreferencesWindow.shared.show()
    }

    /// `NSApp.terminate` alone is not enough: the LaunchAgent has KeepAlive set, so launchd
    /// brings us straight back. Unloading the job stops that until the next login re-loads it.
    /// Launched by hand there is no job, and the terminate below covers it.
    @objc private func quit() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = ["bootout", "gui/\(getuid())/com.mr.alttab"]
        try? task.run()
        task.waitUntilExit()
        NSApp.terminate(nil)
    }

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        return entry
    }



    /// Rebuilt on every open rather than kept in sync: the counts and the grant can both change
    /// without us being told, and the menu is only ever read at the moment it is shown.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if AXIsProcessTrusted() {
            let count = WindowList.snapshot().count
            menu.addItem(disabled(count == 1 ? "1 window" : "\(count) windows"))
        } else {
            // Not a warning for its own sake: without the grant the panel lists applications
            // with no window names and cannot raise anything, which otherwise just looks broken.
            let entry = NSMenuItem(title: "Needs Accessibility…",
                                   action: #selector(openAccessibilitySettings), keyEquivalent: "")
            entry.target = self
            menu.addItem(entry)
        }

        menu.addItem(.separator())

        let shortcuts = Shortcuts.current()
        for binding in Binding.allCases {
            guard let shortcut = shortcuts[binding] else { continue }
            let entry = NSMenuItem(title: binding.title,
                                   action: #selector(openPreferences), keyEquivalent: "")
            entry.target = self
            // The chord as the item's own key equivalent, so it renders right-aligned and grey
            // exactly like every other shortcut in the menu bar.
            entry.attributedTitle = NSAttributedString(string: "\(binding.title)\t\(shortcut.label)")
            menu.addItem(entry)
        }

        menu.addItem(.separator())
        let change = NSMenuItem(title: "Change Shortcuts…",
                                action: #selector(openPreferences), keyEquivalent: "")
        change.target = self
        menu.addItem(change)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit alt-tab (until next login)",
                              action: #selector(self.quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }
}
