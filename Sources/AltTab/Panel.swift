import AppKit
import SwitchCore

/// The window that appears: one row of window pictures, the selected one lit, and the title of
/// that window underneath.
///
/// The pictures arrive after the panel does. A capture costs 45–50 ms each and the panel has a
/// budget of a few, so every tile is drawn immediately with the application icon and repainted
/// when its own picture lands — the slot is reserved at full size from the first frame, so
/// nothing moves under the eye when it does.
///
/// Built once at launch and never closed, only emptied and ordered out. Construction is the
/// expensive part by an order of magnitude — tens of milliseconds against well under one to
/// show a window that already exists — so the first ⌥Tab must never be the one that pays it.
///
/// It renders exactly the array it is handed and never asks who the windows are. That is what
/// keeps the enumeration off the paint path.
@MainActor
enum Panel {

    private static let maxTile: CGFloat = 176
    private static let minTile: CGFloat = 96
    private static let aspect: CGFloat = 110.0 / 176.0
    private static let gap: CGFloat = 12
    private static let padding: CGFloat = 20
    private static let titleHeight: CGFloat = 20

    private static var panel: NSPanel?
    private static var tiles: [TileView] = []
    private static var titleField: NSTextField?
    private static var noteField: NSTextField?
    private static var icons: [pid_t: NSImage] = [:]
    private static var previousApp: NSRunningApplication?
    private static var shown: [WindowInfo] = []
    /// Which round of captures the tiles currently belong to. A picture that arrives after the
    /// panel has moved on is for a window that is no longer in that slot.
    private static var round = 0

    /// Pays for the window, the view tree and the icon cache before anything is asked of them.
    static func warm() {
        _ = built()
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            icons[app.processIdentifier] = app.icon
        }
        Thumbnails.warm()
    }

    static func show(_ windows: [WindowInfo], selected: Int) {
        let panel = built()
        shown = windows
        layout(windows, selected: selected)
        requestPictures(for: windows)

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
        for (i, tile) in tiles.enumerated() where !tile.isHidden {
            tile.setSelected(i == index)
        }
        titleField?.stringValue = index < shown.count ? shown[index].title : ""
    }

    /// Cancel path. Focus goes back where it came from — the panel activates, so leaving it
    /// out would make Escape a way of quietly changing which app is frontmost.
    static func hide() {
        orderOut()
        previousApp?.activate()
        previousApp = nil
    }

    /// Commit path: the panel gets out of the way without touching focus, because the raise
    /// that follows is what decides where focus lands.
    static func dismiss() {
        orderOut()
        previousApp = nil
    }

    private static func orderOut() {
        // Alpha first: ordering out goes through the WindowServer and can lag, and a panel that
        // is still painted after the switch reads as the switch not having happened.
        panel?.alphaValue = 0
        panel?.orderOut(nil)
        shown = []
    }

    /// The one line of text the app ever writes to the user. Cleared on the next open.
    static func note(_ message: String?) {
        noteField?.stringValue = message ?? ""
        noteField?.isHidden = message == nil
    }

    private static func built() -> NSPanel {
        if let panel { return panel }

        let p = SwitcherPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 120),
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
        background.layer?.cornerRadius = 16
        background.layer?.masksToBounds = true
        p.contentView = background

        // A pool, because allocating views is the cost that showed up in every measurement.
        tiles = (0..<24).map { _ in
            let tile = TileView(frame: .zero)
            tile.isHidden = true
            background.addSubview(tile)
            return tile
        }

        let title = NSTextField(labelWithString: "")
        title.font = .systemFont(ofSize: 13)
        title.alignment = .center
        title.lineBreakMode = .byTruncatingTail
        background.addSubview(title)
        titleField = title

        let note = NSTextField(labelWithString: "")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.alignment = .center
        note.isHidden = true
        background.addSubview(note)
        noteField = note

        panel = p
        return p
    }

    private static func layout(_ windows: [WindowInfo], selected: Int) {
        let count = min(windows.count, tiles.count)
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let available = screen.visibleFrame.width - 120

        // Tiles shrink rather than the row wrapping or scrolling: a switcher you have to read
        // twice is slower than one whose pictures are small, and the selection is what you are
        // looking at anyway.
        var tileWidth = maxTile
        if count > 0 {
            let widest = (available - padding * 2 - gap * CGFloat(count - 1)) / CGFloat(count)
            tileWidth = max(minTile, min(maxTile, widest))
        }
        let tileHeight = (tileWidth * aspect).rounded()

        let noteText = noteField?.stringValue ?? ""
        let noteHeight: CGFloat = noteText.isEmpty ? 0 : 16
        let row = CGFloat(count) * tileWidth + gap * CGFloat(max(count - 1, 0))
        // A floor on the width, because the panel is as wide as its tiles and one tile is not as
        // wide as a window title. Without it the line underneath is truncated while most of the
        // screen sits empty beside it.
        let width = max(row + padding * 2, min(380, available))
        let height = padding * 2 + tileHeight + 8 + titleHeight + noteHeight
        let left = (width - row) / 2

        for (i, tile) in tiles.enumerated() {
            guard i < count else { tile.isHidden = true; continue }
            tile.isHidden = false
            tile.frame = NSRect(x: left + CGFloat(i) * (tileWidth + gap),
                                y: height - padding - tileHeight,
                                width: tileWidth, height: tileHeight)
            tile.setIcon(self.icon(for: windows[i].pid))
            // Yesterday's picture, if there is one, so a window that has not changed is never
            // shown as a blank slot while it is re-captured.
            tile.setPicture(Thumbnails.cached(windows[i].id))
            tile.setSelected(i == selected)
        }

        titleField?.frame = NSRect(x: padding, y: padding + noteHeight,
                                   width: max(width - padding * 2, 10), height: titleHeight)
        titleField?.stringValue = selected < windows.count ? windows[selected].title : ""
        noteField?.frame = NSRect(x: padding, y: padding - 4, width: max(width - padding * 2, 10), height: 14)

        guard let panel else { return }
        let frame = screen.visibleFrame
        panel.setFrame(NSRect(x: frame.midX - width / 2,
                              y: frame.midY - height / 2,
                              width: width, height: height),
                       display: false)
        panel.alphaValue = 1
    }

    /// Asks for fresh pictures, and drops any that arrive for a panel that has since closed or
    /// been rebuilt with a different set of windows.
    private static func requestPictures(for windows: [WindowInfo]) {
        guard Thumbnails.isPermitted else { return }
        let ids = windows.map(\.id)
        Thumbnails.capture(ids) { id, image, generation in
            guard generation == round, let index = shown.firstIndex(where: { $0.id == id }),
                  index < tiles.count else { return }
            tiles[index].setPicture(image)
        }
        round += 1
    }

    private static func icon(for pid: pid_t) -> NSImage? {
        if let cached = icons[pid] { return cached }
        let icon = NSRunningApplication(processIdentifier: pid)?.icon
        icons[pid] = icon
        return icon
    }

    /// AppKit refuses key focus to a borderless window unless it is asked for by name, and the
    /// refusal is silent. Without this the panel takes no keyboard focus at all, and Escape
    /// never reaches it. Committing does not depend on this — see `Trigger.watchForRelease`,
    /// which exists because focus is exactly the thing that cannot be relied on here.
    private final class SwitcherPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        // Main is a different thing: it decides which window owns the menu bar and the document
        // proxy, neither of which a transient panel should take.
        override var canBecomeMain: Bool { false }
    }

    /// One window: its picture, its application icon in the corner, and the highlight behind it.
    ///
    /// Bare layers rather than `NSImageView`s: the row is a fixed number of fixed-size tiles
    /// whose contents are known before it is shown, so there is nothing for AppKit's layout,
    /// responder-chain and drag-and-drop machinery to contribute.
    private final class TileView: NSView {
        private let pictureLayer = CALayer()
        private let iconLayer = CALayer()
        private var hasPicture = false

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.cornerRadius = 10
            pictureLayer.contentsGravity = .resizeAspect
            pictureLayer.cornerRadius = 6
            pictureLayer.masksToBounds = true
            iconLayer.contentsGravity = .resizeAspect
            layer?.addSublayer(pictureLayer)
            layer?.addSublayer(iconLayer)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            pictureLayer.frame = bounds.insetBy(dx: 6, dy: 6)
            let badge = min(bounds.height * 0.27, 30)
            if hasPicture {
                // Tucked into the corner of the picture, big enough to name the application at a
                // glance without covering what the picture is for.
                iconLayer.frame = CGRect(x: bounds.maxX - badge - 4, y: 4, width: badge, height: badge)
            } else {
                // Nothing to sit on yet, so the icon *is* the tile.
                let side = min(bounds.height, bounds.width) - 16
                iconLayer.frame = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2,
                                         width: side, height: side)
            }
        }

        func setIcon(_ image: NSImage?) {
            iconLayer.contents = image
            needsLayout = true
        }

        func setPicture(_ image: NSImage?) {
            pictureLayer.contents = image
            hasPicture = image != nil
            needsLayout = true
        }

        func setSelected(_ selected: Bool) {
            layer?.backgroundColor = selected
                ? NSColor.white.withAlphaComponent(0.22).cgColor
                : NSColor.clear.cgColor
        }
    }
}
