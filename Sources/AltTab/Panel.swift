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

    private static let gap: CGFloat = 12
    /// AltTab's own numbers for this style and size on macOS 26: 28 around the pane, 18 on a
    /// tile, a 26pt application icon. Read out of their Appearance.swift rather than guessed.
    private static let padding: CGFloat = 28
    /// The icon row: AltTab's edge inset, icon and intra-cell padding, which is what makes our
    /// tile the same height as theirs.
    static var headerHeight: CGFloat { tileInset + iconSize + iconToPicture }
    /// AltTab's own value for this style and size is 26; this is deliberately larger. The
    /// picture loses the difference, since the row height is fixed and the icon sits above it.
    static let iconSize: CGFloat = 32
    /// AltTab's `edgeInsetsSize` for this style: the breathing room between a tile's edge
    /// and the picture inside it.
    static let tileInset: CGFloat = 12
    /// Their `intraCellPadding`, between the icon row and the picture.
    private static let iconToPicture: CGFloat = 5
    private static let interCell: CGFloat = 1

    /// How big a picture may be, worked out the way AltTab works it out.
    ///
    /// Their sizing is not two numbers, it is a calculation over the screen: how much of it the
    /// panel may take, how many rows of tiles have to fit in that, and how wide a tile may be as
    /// a fraction of the row. Copying the two numbers it lands on for this display would be
    /// right here and wrong on the next one, so this is the calculation.
    struct Box {
        let pictureWidthMax: CGFloat
        let pictureWidthMin: CGFloat
        let pictureHeightMax: CGFloat
    }

    static func box(for screen: NSScreen) -> Box {
        let frame = screen.frame
        // 600 / the screen's width in millimetres, so a very wide display gives the panel a
        // smaller share of itself. Anything narrower than about 67cm lands on the 0.9 ceiling.
        var widthShare: CGFloat = 0.9
        if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
            let millimetres = CGDisplayScreenSize(number).width
            if millimetres > 0 { widthShare = min(0.9, max(0.45, 600 / millimetres)) }
        }
        let heightShare: CGFloat = 0.8
        let rows: CGFloat = frame.width >= frame.height ? 4 : 7

        let rowsWidth = (frame.width * widthShare - padding * 2).rounded()
        let rowsHeight = (frame.height * heightShare - padding * 2).rounded()
        let rowHeight = ((rowsHeight - interCell) / rows - interCell).rounded()

        // How wide a tile may be, as a fraction of the row: enough that a fullscreen window
        // fills its tile vertically, and that a narrow one still shows a few words of title.
        let panelRatio = (frame.width * widthShare) / (frame.height * heightShare)
        let minShare = panelRatio >= 1 ? 0.7 / (panelRatio * rows) : 1.3 / rows
        let maxShare = panelRatio >= 1 ? 1.5 / (panelRatio * rows) : 2.1 / rows

        return Box(
            pictureWidthMax: rowsWidth * min(0.30, maxShare) - interCell * 2 - tileInset * 2,
            pictureWidthMin: rowsWidth * max(0.09, minShare) - interCell * 2 - tileInset * 2,
            pictureHeightMax: rowHeight - tileInset * 2 - iconToPicture - iconSize)
    }

    /// The largest any picture will be drawn, which is also the largest worth capturing.
    static var captureSize: CGSize {
        let box = box(for: NSScreen.main ?? NSScreen.screens[0])
        return CGSize(width: max(box.pictureWidthMax, 1), height: max(box.pictureHeightMax, 1))
    }

    private static var panel: NSPanel?
    private static var tiles: [TileView] = []
    private static var noteField: NSTextField?
    private static var icons: [pid_t: NSImage] = [:]
    private static var previousApp: NSRunningApplication?
    private static var shown: [WindowInfo] = []
    /// Which round of captures the tiles currently belong to. A picture that arrives after the
    /// panel has moved on is for a window that is no longer in that slot.
    private static var round = 0
    /// Asked when the cross on a tile is clicked. The panel does not close anything itself: it
    /// says which window, and stays out of what that means.
    static var onCloseRequested: ((WindowInfo) -> Void)?

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
    fileprivate static func withoutAnimation(_ body: () -> Void) {
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

        // Apple's own dark glass. `.behindWindow` is what makes it a blur of the desktop rather
        // than of nothing — `.withinWindow` samples this window's own contents, which are the
        // pictures we are drawing on top.
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 43
        background.layer?.masksToBounds = true
        // `cornerRadius` alone rounds the view's own drawing and nothing else: the behind-window
        // blur is composited by the WindowServer as a plain rectangle, and its square corners
        // stick out past the rounded pane — bright ones over a bright desktop. `maskImage` is
        // the only thing the material itself honours.
        background.maskImage = roundedMask(radius: 43)
        p.contentView = background

        // The material alone reads grey over a bright desktop, so a black veil deepens it. It
        // cannot be the 80% of the flat version and still be glass: past roughly half, there is
        // nothing of the blur left to see. This is the dial between the two.
        let veil = NSView(frame: background.bounds)
        veil.autoresizingMask = [.width, .height]
        veil.wantsLayer = true
        veil.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        background.addSubview(veil)

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

    /// A rounded rectangle that stretches: the corners are kept and only the middle is
    /// repeated, so one small image masks the pane at any size it takes.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    private static func layout(_ windows: [WindowInfo], selected: Int) {
        withoutAnimation { place(windows, selected: selected) }
    }

    private static func place(_ windows: [WindowInfo], selected: Int) {
        let count = min(windows.count, tiles.count)
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let available = screen.visibleFrame.width - 120

        let box = box(for: screen)

        /// The size a window's picture is drawn at: its own proportions, fitted inside the box,
        /// and never enlarged past its own size — a small window blown up to fill a tile is a
        /// blurred small window, so AltTab leaves those at 1:1 and so do we.
        func picture(_ window: WindowInfo) -> CGSize {
            let size = window.size
            guard size.width > 0, size.height > 0 else {
                return CGSize(width: box.pictureWidthMax, height: box.pictureHeightMax)
            }
            if size.width <= box.pictureWidthMax, size.height <= box.pictureHeightMax { return size }
            let fit = min(box.pictureWidthMax / size.width, box.pictureHeightMax / size.height)
            return CGSize(width: (size.width * fit).rounded(), height: (size.height * fit).rounded())
        }

        let pictures = (0..<count).map { picture(windows[$0]) }
        // A floor on the tile, not on the picture: a tall window keeps its narrow picture and is
        // given enough tile around it for a few words of its title to be readable.
        let tileWidths = pictures.map {
            max($0.width, box.pictureWidthMin).rounded() + tileInset * 2
        }
        var pictureArea = box.pictureHeightMax
        var widths = tileWidths
        var row = widths.reduce(0, +) + gap * CGFloat(max(count - 1, 0))
        // One row where AltTab would wrap to four, so a long list has to shrink to fit. The
        // whole row shrinks together: pictures stay comparable to each other, which is what
        // makes a row of them readable at a glance.
        let widest = available - padding * 2
        if row > widest, row > 0 {
            let scale = widest / row
            widths = widths.map { ($0 * scale).rounded() }
            pictureArea = (pictureArea * scale).rounded()
            row = widths.reduce(0, +) + gap * CGFloat(max(count - 1, 0))
        }

        let noteText = noteField?.stringValue ?? ""
        let noteHeight: CGFloat = noteText.isEmpty ? 0 : 18
        // No floor on the width. There used to be one, from when a tile could be as narrow as
        // its icon; a tile has its own minimum now, and the floor only served to pad the sides
        // of a short row — 41 points against the 28 above and below it.
        let width = row + padding * 2
        let fullTile = headerHeight + pictureArea + tileInset
        let panelHeight = padding * 2 + fullTile + noteHeight
        var x = (width - row) / 2

        for (i, tile) in tiles.enumerated() {
            guard i < count else { tile.isHidden = true; continue }
            tile.isHidden = false
            tile.frame = NSRect(x: x, y: padding + noteHeight,
                                width: widths[i], height: fullTile)
            x += widths[i] + gap
            // The window's own title, not the application's name: the icon beside it already
            // says which application it is, and spending the line on both leaves no room for
            // the half that distinguishes one window from another — "qemu-system-aarch64 —…"
            // names the application twice and the window not at all. `WindowInfo` already falls
            // back to the application name for a window that has no title of its own.
            tile.setIcon(self.icon(for: windows[i].pid), label: windows[i].title, subject: windows[i])
            // The picture is drawn at its own size inside the tile rather than stretched to it,
            // so a window narrower or shorter than the box keeps its proportions and its scale.
            let fit = min(1, min(widths[i] - tileInset * 2, pictures[i].width) / max(pictures[i].width, 1),
                          pictureArea / max(pictures[i].height, 1))
            tile.setPictureSize(CGSize(width: (pictures[i].width * fit).rounded(),
                                       height: (pictures[i].height * fit).rounded()))
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
        private let crossLayer = CALayer()
        private var text = ""
        private var subject: WindowInfo?
        private var isHot = false
        private var pictureSize: CGSize = .zero

        // AltTab's own 14, at semibold: the weight carries the emphasis, so the size does not
        // have to.
        private static let font = NSFont.systemFont(ofSize: 14, weight: .semibold)

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
            layer?.cornerRadius = 18
            pictureLayer.contentsGravity = .resizeAspect
            // Square, deliberately: this is a photograph of a window and windows have corners.
            // Rounding it a second time reads as a mistake next to the rounded tile behind it,
            // which is the shape that is meant to be soft.
            pictureLayer.masksToBounds = true
            iconLayer.contentsGravity = .resizeAspect
            labelLayer.font = Self.font
            labelLayer.fontSize = Self.font.pointSize
            labelLayer.foregroundColor = NSColor.labelColor.cgColor
            labelLayer.truncationMode = .end
            labelLayer.alignmentMode = .left
            crossLayer.contents = Self.cross
            crossLayer.isHidden = true
            for sublayer in [pictureLayer, iconLayer, labelLayer, crossLayer] as [CALayer] {
                sublayer.actions = Self.still
            }
            layer?.addSublayer(pictureLayer)
            layer?.addSublayer(iconLayer)
            layer?.addSublayer(labelLayer)
            layer?.addSublayer(crossLayer)
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
            let iconSide = Panel.iconSize
            // At the inset, not centred in the header: AltTab places its icon at
            // (edgeInsets, edgeInsets), so the space above it is the space beside it.
            iconLayer.frame = CGRect(x: inset, y: bounds.height - inset - iconSide,
                                     width: iconSide, height: iconSide)

            let textHeight = (text as NSString).size(withAttributes: [.font: Self.font]).height
            labelLayer.frame = CGRect(x: iconLayer.frame.maxX + 4,
                                      y: iconLayer.frame.midY - textHeight / 2,
                                      width: max(bounds.width - inset - (iconLayer.frame.maxX + 4), 0),
                                      height: textHeight)

            // Centred in what is left under the header, at the size it was given.
            let area = CGRect(x: inset, y: inset,
                              width: bounds.width - inset * 2,
                              height: bounds.height - header - inset)
            let drawn = pictureSize == .zero ? area.size : pictureSize
            pictureLayer.frame = CGRect(x: (area.midX - drawn.width / 2).rounded(),
                                        y: (area.midY - drawn.height / 2).rounded(),
                                        width: drawn.width, height: drawn.height)

            // Top-left of the picture, where a window's own close button is.
            let cross: CGFloat = 20
            crossLayer.frame = CGRect(x: pictureLayer.frame.minX + 6,
                                      y: pictureLayer.frame.maxY - cross - 6,
                                      width: cross, height: cross)
        }

        func setIcon(_ image: NSImage?, label: String, subject: WindowInfo) {
            iconLayer.contents = image
            text = label
            labelLayer.string = label
            self.subject = subject
            needsLayout = true
        }

        func setPictureSize(_ size: CGSize) {
            pictureSize = size
            needsLayout = true
        }

        func setPicture(_ image: NSImage?) {
            pictureLayer.contents = image
            needsLayout = true
        }

        func setSelected(_ selected: Bool) {
            // The system accent colour, which is the blue AltTab uses — it reads
            // `controlAccentColor`, so both follow whatever the user set in System Settings.
            layer?.backgroundColor = selected
                ? NSColor.controlAccentColor.withAlphaComponent(0.2).cgColor
                : NSColor.clear.cgColor
            layer?.borderColor = NSColor.controlAccentColor.cgColor
            layer?.borderWidth = selected ? 3 : 0
        }

        // MARK: - The cross

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            // `.activeAlways`, because the panel is up for half a second and may not be the key
            // window for all of it.
            addTrackingArea(NSTrackingArea(rect: bounds,
                                           options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
                                           owner: self))
        }

        override func mouseEntered(with event: NSEvent) { showCross(true) }

        override func mouseExited(with event: NSEvent) {
            showCross(false)
            setHot(false)
        }

        override func mouseMoved(with event: NSEvent) {
            setHot(isOnCross(convert(event.locationInWindow, from: nil)))
        }

        private func setHot(_ hot: Bool) {
            guard hot != isHot else { return }
            isHot = hot
            Panel.withoutAnimation { crossLayer.contents = hot ? Self.crossHot : Self.cross }
        }

        /// A few points of slack around the disc, because a 20pt target asked for pixel accuracy
        /// would be a target you have to aim at.
        private func isOnCross(_ point: NSPoint) -> Bool {
            !crossLayer.isHidden && crossLayer.frame.insetBy(dx: -4, dy: -4).contains(point)
        }

        override func mouseDown(with event: NSEvent) {
            guard isOnCross(convert(event.locationInWindow, from: nil)), let subject else { return }
            Panel.onCloseRequested?(subject)
        }

        private func showCross(_ visible: Bool) {
            Panel.withoutAnimation { crossLayer.isHidden = !visible }
        }

        /// A red disc with a black cross, drawn once and shared: every tile shows the same one,
        /// and it is only ever on screen while the pointer is over a tile. The darker one is
        /// what it becomes under the pointer — the same feedback a real close button gives.
        private static func crossImage(hot: Bool) -> NSImage {
            let side: CGFloat = 20
            // The red of a window's own close button, and the same red pressed.
            let red = hot
                ? NSColor(srgbRed: 0.83, green: 0.28, blue: 0.25, alpha: 1)
                : NSColor(srgbRed: 1.00, green: 0.37, blue: 0.34, alpha: 1)
            return NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
                red.setFill()
                NSBezierPath(ovalIn: rect).fill()
                let path = NSBezierPath()
                let inset = side * 0.33
                path.move(to: NSPoint(x: inset, y: inset))
                path.line(to: NSPoint(x: side - inset, y: side - inset))
                path.move(to: NSPoint(x: inset, y: side - inset))
                path.line(to: NSPoint(x: side - inset, y: inset))
                path.lineWidth = 1.9
                path.lineCapStyle = .round
                NSColor.black.setStroke()
                path.stroke()
                return true
            }
        }

        private static let cross = crossImage(hot: false)
        private static let crossHot = crossImage(hot: true)
    }
}
