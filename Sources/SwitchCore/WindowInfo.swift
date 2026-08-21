import ApplicationServices

/// One row of the switcher.
///
/// Not `WindowRef`, which is what it wants to be called: Carbon still typedefs that name in
/// Quickdraw's headers, and `Trigger.swift` imports Carbon, so the two collide at every use
/// site in the shell target.
///
/// `element` is what makes the row actionable and is why enumeration runs AX-first: the
/// Accessibility bridge is one-directional. `_AXUIElementGetWindow` maps an element to a
/// window id, and there is no call back the other way — so a list built from `CGWindowList`
/// can render a window it has no way to raise.
///
/// `title` may be the application name. An untrusted process gets no titles at all, and a
/// stalled one gets none before the deadline; both fall back to the app name rather than to
/// an empty row.
public struct WindowInfo: Equatable {
    public let id: CGWindowID
    public let pid: pid_t
    public let appName: String
    public let title: String
    public let element: AXUIElement?
    /// The window's own size, so a tile can be shaped like the window it stands for instead of
    /// putting a narrow picture in a wide box.
    public let size: CGSize
    /// Minimized windows are in the list but not of it: they have no Z position to be ordered
    /// by, no picture to be taken of them, and raising one has to un-minimize it first.
    public let isMinimized: Bool
    /// The same, for a window whose application is hidden — off the screen for a different
    /// reason and undone by a different call, so the two are kept apart.
    public let isAppHidden: Bool
    /// Either way: not on the screen, which is what the tile draws and the capture skips.
    public var isOffscreen: Bool { isMinimized || isAppHidden }

    public init(id: CGWindowID, pid: pid_t, appName: String, title: String,
                element: AXUIElement?, size: CGSize,
                isMinimized: Bool = false, isAppHidden: Bool = false) {
        self.id = id
        self.pid = pid
        self.appName = appName
        self.title = title
        self.element = element
        self.size = size
        self.isMinimized = isMinimized
        self.isAppHidden = isAppHidden
    }

    public static func == (a: WindowInfo, b: WindowInfo) -> Bool { a.id == b.id }
}
