import AppKit
import SwitchCore

/// Whether there is a menu bar icon at all.
///
/// There is none by default: alt-tab is meant to be a key combination and nothing else, and a
/// background agent that plants a permanent icon to say "I exist" is charging the menu bar rent
/// for information nobody asked for. The icon appears while the settings window is open — that
/// is what opening the application does — and goes away with it, unless it has been asked to
/// stay.
@MainActor
enum MenuBar {

    private static var controller: StatusItemController?

    static var isVisible: Bool { controller != nil }

    static func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        controller = visible ? StatusItemController() : nil
    }
}

/// The menu bar presence: a small Tab key.
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

    deinit {
        // The status bar owns its items; dropping the controller is not enough to take the icon
        // out of the menu bar, and `MainActor.assumeIsolated` is the only way to say so from a
        // deinit that the compiler cannot see is already on the main thread.
        MainActor.assumeIsolated { NSStatusBar.system.removeStatusItem(item) }
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

    /// Takes the icon away without touching anything else: the switcher keeps running and the
    /// chord keeps working. This is the way back out for someone who opened the application to
    /// change one thing and does not want the icon left behind.
    @objc private func hideIcon() {
        Settings.showsMenuBarIcon = false
        // Not synchronously: this runs from inside the menu's own tracking, and tearing the item
        // down under it takes the menu with it mid-event.
        DispatchQueue.main.async { MainActor.assumeIsolated { MenuBar.setVisible(false) } }
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

    private func entry(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
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
            menu.addItem(entry("Needs Accessibility…", #selector(openAccessibilitySettings)))
        }

        menu.addItem(.separator())

        let shortcuts = Shortcuts.current()
        for binding in Binding.allCases {
            guard let shortcut = shortcuts[binding] else { continue }
            let item = entry(binding.title, #selector(openPreferences))
            // The chord as the item's own key equivalent, so it renders right-aligned and grey
            // exactly like every other shortcut in the menu bar.
            item.attributedTitle = NSAttributedString(string: "\(binding.title)\t\(shortcut.label)")
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(entry("Settings…", #selector(openPreferences), key: ","))
        menu.addItem(entry("Hide This Icon", #selector(hideIcon)))
    }
}
