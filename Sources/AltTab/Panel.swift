import AppKit
import SwitchCore

/// The window that appears: one row of tiles, each a line naming the window above a picture of
/// it, with the selected tile lit.
///
/// The label sits above its own picture rather than under the row, which is how AltTab does it
/// and is the arrangement that survives having more than one window: a single line under the
/// row can only ever describe the selection, so every other tile is unlabelled.
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

    /// Pictures are all the same height and each is as wide as its own window — so a tile is
    /// shaped like the window it stands for, and the highlight behind the selected one is that
    /// shape rather than a wide box with a narrow picture adrift in it.
    private static let pictureHeight: CGFloat = 150
    private static let minPicture: CGFloat = 112
    private static let maxPicture: CGFloat = 264
    private static let gap: CGFloat = 12
    private static let padding: CGFloat = 20
    static let headerHeight: CGFloat = 28
    static let tileInset: CGFloat = 7

    private static var panel: NSPanel?
    private static var tiles: [TileView] = []
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
        withoutAnimation {
            for (i, tile) in tiles.enumerated() where !tile.isHidden {
                tile.setSelected(i == index)
            }
        }
    }

    /// Layer changes are animated unless something says otherwise, and every change this panel
    /// makes is meant to be already true by the time it is looked at.
    private static func withoutAnimation(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
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

        // Dark aqua whatever the system is set to. Every colour below resolves through the
        // appearance, and on a black panel a light-mode `labelColor` is black text on black.
        p.appearance = NSAppearance(named: .darkAqua)

        // A flat dark pane rather than a blur: at this opacity there is nothing left of what is
        // behind to be worth blurring, and the blur's own tint is what kept it grey.
        let background = NSView()
        background.wantsLayer = true
        background.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.90).cgColor
        background.layer?.cornerRadius = 22
        background.layer?.masksToBounds = true
        p.contentView = background

        // A pool, because allocating views is the cost that showed up in every measurement.
        tiles = (0..<24).map { _ in
            let tile = TileView(frame: .zero)
            tile.isHidden = true
            background.addSubview(tile)
            return tile
        }

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
        withoutAnimation { place(windows, selected: selected) }
    }

    private static func place(_ windows: [WindowInfo], selected: Int) {
        let count = min(windows.count, tiles.count)
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let available = screen.visibleFrame.width - 120

        /// Each picture's width from its window's own proportions, clamped so a very tall window
        /// still has room for a label and a very wide one does not take the whole screen.
        func widths(pictureHeight: CGFloat) -> [CGFloat] {
            (0..<count).map { i in
                let size = windows[i].size
                let ratio = size.width > 0 && size.height > 0 ? size.width / size.height : 1.6
                return min(max((pictureHeight * ratio).rounded(), minPicture), maxPicture)
                    + tileInset * 2
            }
        }

        // The row shrinks as a whole when it does not fit, rather than any one tile being
        // singled out: the pictures stay comparable to each other, which is what makes a row of
        // them readable at a glance.
        var height = pictureHeight
        var tileWidths = widths(pictureHeight: height)
        var row = tileWidths.reduce(0, +) + gap * CGFloat(max(count - 1, 0))
        let widest = available - padding * 2
        if row > widest, row > 0 {
            height = max(70, (height * widest / row).rounded())
            tileWidths = widths(pictureHeight: height)
            row = tileWidths.reduce(0, +) + gap * CGFloat(max(count - 1, 0))
        }

        let noteText = noteField?.stringValue ?? ""
        let noteHeight: CGFloat = noteText.isEmpty ? 0 : 18
        let width = max(row + padding * 2, min(300, available))
        let fullTile = headerHeight + height + tileInset
        let panelHeight = padding * 2 + fullTile + noteHeight
        var x = (width - row) / 2

        for (i, tile) in tiles.enumerated() {
            guard i < count else { tile.isHidden = true; continue }
            tile.isHidden = false
            tile.frame = NSRect(x: x, y: padding + noteHeight,
                                width: tileWidths[i], height: fullTile)
            x += tileWidths[i] + gap
            // The window's own title, not the application's name: the icon beside it already
            // says which application it is, and spending the line on both leaves no room for
            // the half that distinguishes one window from another — "qemu-system-aarch64 —…"
            // names the application twice and the window not at all. `WindowInfo` already falls
            // back to the application name for a window that has no title of its own.
            tile.setIcon(self.icon(for: windows[i].pid), label: windows[i].title)
            // Yesterday's picture, if there is one, so a window that has not changed is never
            // shown as a blank slot while it is re-captured.
            tile.setPicture(Thumbnails.cached(windows[i].id))
            tile.setSelected(i == selected)
        }

        noteField?.frame = NSRect(x: padding, y: padding - 2, width: max(width - padding * 2, 10), height: 16)

        guard let panel else { return }
        let frame = screen.visibleFrame
        panel.setFrame(NSRect(x: frame.midX - width / 2,
                              y: frame.midY - panelHeight / 2,
                              width: width, height: panelHeight),
                       display: false)
        panel.alphaValue = 1
    }

    /// Asks for fresh pictures, and drops any that arrive for a panel that has since closed or
    /// been rebuilt with a different set of windows.
    private static func requestPictures(for windows: [WindowInfo]) {
        guard Thumbnails.isPermitted else { return }
        round = Thumbnails.capture(windows.map(\.id)) { id, image, generation in
            guard generation == round, let index = shown.firstIndex(where: { $0.id == id }),
                  index < tiles.count else { return }
            withoutAnimation { tiles[index].setPicture(image) }
        }
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

    /// One window: a line naming it, and its picture below.
    ///
    /// Bare layers rather than `NSImageView`s and `NSTextField`s: the row is a fixed number of
    /// fixed-size tiles whose contents are known before it is shown, so there is nothing for
    /// AppKit's layout, responder-chain and drag-and-drop machinery to contribute.
    private final class TileView: NSView {
        private let pictureLayer = CALayer()
        private let iconLayer = CALayer()
        private let labelLayer = CATextLayer()
        private var text = ""

        private static let font = NSFont.systemFont(ofSize: 14, weight: .regular)

        /// Core Animation animates every layer change it is not told to leave alone, including
        /// the very first one — a tile is created at zero size, so its first real frame is a
        /// growth from nothing, which is the zoom seen on the first ⌥Tab of a session. Pictures
        /// landing afterwards would cross-fade in for the same reason.
        private static let still: [String: CAAction] = [
            "contents": NSNull(), "bounds": NSNull(), "position": NSNull(),
            "frame": NSNull(), "backgroundColor": NSNull(), "opacity": NSNull(),
            "hidden": NSNull(), "string": NSNull(),
        ]

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.actions = Self.still
            layer?.cornerRadius = 14
            pictureLayer.contentsGravity = .resizeAspect
            pictureLayer.cornerRadius = 10
            pictureLayer.masksToBounds = true
            iconLayer.contentsGravity = .resizeAspect
            labelLayer.font = Self.font
            labelLayer.fontSize = Self.font.pointSize
            labelLayer.foregroundColor = NSColor.labelColor.cgColor
            labelLayer.truncationMode = .end
            labelLayer.alignmentMode = .left
            for sublayer in [pictureLayer, iconLayer, labelLayer] as [CALayer] {
                sublayer.actions = Self.still
            }
            layer?.addSublayer(pictureLayer)
            layer?.addSublayer(iconLayer)
            layer?.addSublayer(labelLayer)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            let scale = window?.backingScaleFactor ?? 2
            // Text rendered at the window's own scale; left at 1 it is visibly soft on a Retina
            // display, which is the only place it will ever be seen.
            labelLayer.contentsScale = scale
            pictureLayer.contentsScale = scale

            let inset = Panel.tileInset
            let header = Panel.headerHeight
            // AppKit measures from the bottom, so the header is the top of the tile and the
            // picture is everything under it.
            let iconSide = header - 6
            iconLayer.frame = CGRect(x: inset, y: bounds.height - header + 2,
                                     width: iconSide, height: iconSide)

            let textHeight = (text as NSString).size(withAttributes: [.font: Self.font]).height
            labelLayer.frame = CGRect(x: iconLayer.frame.maxX + 6,
                                      y: bounds.height - header + (header - textHeight) / 2,
                                      width: max(bounds.width - inset - (iconLayer.frame.maxX + 6), 0),
                                      height: textHeight)

            pictureLayer.frame = CGRect(x: inset, y: inset,
                                        width: bounds.width - inset * 2,
                                        height: bounds.height - header - inset)
        }

        func setIcon(_ image: NSImage?, label: String) {
            iconLayer.contents = image
            text = label
            labelLayer.string = label
            needsLayout = true
        }

        func setPicture(_ image: NSImage?) {
            pictureLayer.contents = image
            needsLayout = true
        }

        func setSelected(_ selected: Bool) {
            layer?.backgroundColor = selected
                ? NSColor.white.withAlphaComponent(0.22).cgColor
                : NSColor.clear.cgColor
        }
    }
}
