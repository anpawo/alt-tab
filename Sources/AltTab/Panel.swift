import AppKit
import SwitchCore

/// The window that appears.
///
/// Built once at launch and never closed, only emptied and ordered out. Construction is the
/// expensive part by an order of magnitude — tens of milliseconds against well under one to
/// show a window that already exists — so the first ⌥Tab must never be the one that pays it.
///
/// It renders exactly the array it is handed and never asks who the windows are. That is what
/// keeps the enumeration off the paint path.
@MainActor
enum Panel {

    private static let rowHeight: CGFloat = 44
    private static let width: CGFloat = 560
    private static let padding: CGFloat = 8
    private static let iconSide: CGFloat = 28

    private static var panel: NSPanel?
    private static var rows: [RowView] = []
    private static var noteField: NSTextField?
    private static var icons: [pid_t: NSImage] = [:]
    private static var previousApp: NSRunningApplication?

    /// Pays for the window, the view tree and the icon cache before anything is asked of them.
    static func warm() {
        _ = built()
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            icons[app.processIdentifier] = app.icon
        }
    }

    static func show(_ windows: [WindowInfo], selected: Int) {
        let panel = built()
        layout(windows, selected: selected)

        // Snapshot who had focus *before* we take it, so cancelling can put it back.
        previousApp = NSWorkspace.shared.frontmostApplication

        // Order in before activating. Activating first would pull us to whichever Space macOS
        // last associated this app with; putting the window up first means the Space we join
        // is the one being looked at.
        panel.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKey()
    }

    static func move(to index: Int) {
        for (i, row) in rows.enumerated() where !row.isHidden {
            row.setSelected(i == index)
        }
    }

    /// Cancel path. Focus goes back where it came from — the panel activates, so leaving it
    /// out would make Escape a way of quietly changing which app is frontmost.
    static func hide() {
        panel?.alphaValue = 0
        panel?.orderOut(nil)
        previousApp?.activate()
        previousApp = nil
    }

    /// Commit path: the panel gets out of the way without touching focus, because the raise
    /// that follows is what decides where focus lands.
    static func dismiss() {
        panel?.alphaValue = 0
        panel?.orderOut(nil)
        previousApp = nil
    }

    /// The one line of text the app ever writes to the user. Cleared on the next open.
    static func note(_ message: String?) {
        noteField?.stringValue = message ?? ""
        noteField?.isHidden = message == nil
    }

    private static func built() -> NSPanel {
        if let panel { return panel }

        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: rowHeight),
                        styleMask: [.borderless, .fullSizeContentView],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .popUpMenu
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        // The panel is a glance: it should already be there when you look at it, not scale up
        // from 90% with a fade, which is what a borderless window gets by default.
        p.animationBehavior = .none
        // `moveToActiveSpace`, not `canJoinAllSpaces`: joining every Space makes the panel a
        // permanent resident of all of them, and there is then no such thing as "still open
        // over there" to observe.
        p.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        // Keeps the panel out of its own list, and out of anyone else's.
        p.setAccessibilitySubrole(.unknown)

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.masksToBounds = true
        p.contentView = background

        // A pool, because allocating views is the cost that showed up in every measurement.
        rows = (0..<24).map { _ in
            let row = RowView(frame: .zero)
            row.isHidden = true
            background.addSubview(row)
            return row
        }

        let note = NSTextField(labelWithString: "")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.isHidden = true
        background.addSubview(note)
        noteField = note

        panel = p
        return p
    }

    private static func layout(_ windows: [WindowInfo], selected: Int) {
        let shown = min(windows.count, rows.count)
        let noteText = noteField?.stringValue ?? ""
        let noteHeight: CGFloat = noteText.isEmpty ? 0 : 20
        let height = CGFloat(shown) * rowHeight + padding * 2 + noteHeight

        for (i, row) in rows.enumerated() {
            guard i < shown else { row.isHidden = true; continue }
            let window = windows[i]
            row.isHidden = false
            row.frame = NSRect(x: padding,
                               y: height - noteHeight - padding - CGFloat(i + 1) * rowHeight,
                               width: width - padding * 2, height: rowHeight)
            row.fill(icon: icon(for: window.pid), title: window.title, subtitle: window.appName)
            row.setSelected(i == selected)
        }

        noteField?.frame = NSRect(x: padding + 8, y: padding - 2,
                                  width: width - padding * 2 - 16, height: 16)

        guard let panel else { return }
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let frame = screen.visibleFrame
        panel.setFrame(NSRect(x: frame.midX - width / 2,
                              y: frame.midY - height / 2,
                              width: width, height: height),
                       display: false)
        panel.alphaValue = 1
    }

    private static func icon(for pid: pid_t) -> NSImage? {
        if let cached = icons[pid] { return cached }
        let icon = NSRunningApplication(processIdentifier: pid)?.icon
        icons[pid] = icon
        return icon
    }

    /// One row. Hand-laid-out and layer-backed: the list is short, fixed-height and known in
    /// advance, so nothing here needs a layout pass to discover its own size.
    private final class RowView: NSView {
        private let iconLayer = CALayer()
        private let titleField = NSTextField(labelWithString: "")
        private let subtitleField = NSTextField(labelWithString: "")

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.cornerRadius = 8
            iconLayer.contentsGravity = .resizeAspect
            layer?.addSublayer(iconLayer)
            titleField.font = .systemFont(ofSize: 13)
            titleField.lineBreakMode = .byTruncatingTail
            subtitleField.font = .systemFont(ofSize: 11)
            subtitleField.textColor = .secondaryLabelColor
            subtitleField.lineBreakMode = .byTruncatingTail
            addSubview(titleField)
            addSubview(subtitleField)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            let inset: CGFloat = 8
            // The icon slot is reserved whether or not there is an icon, so a late one never
            // reflows the row under the pointer.
            iconLayer.frame = CGRect(x: inset, y: (bounds.height - Panel.iconSide) / 2,
                                     width: Panel.iconSide, height: Panel.iconSide)
            let textX = inset * 2 + Panel.iconSide
            let textWidth = bounds.width - textX - inset
            titleField.frame = NSRect(x: textX, y: bounds.height / 2 - 1,
                                      width: textWidth, height: 17)
            subtitleField.frame = NSRect(x: textX, y: bounds.height / 2 - 17,
                                         width: textWidth, height: 15)
        }

        func fill(icon: NSImage?, title: String, subtitle: String) {
            iconLayer.contents = icon
            titleField.stringValue = title
            subtitleField.stringValue = subtitle
            needsLayout = true
        }

        func setSelected(_ selected: Bool) {
            layer?.backgroundColor = selected
                ? NSColor.controlAccentColor.withAlphaComponent(0.30).cgColor
                : NSColor.clear.cgColor
        }
    }
}
