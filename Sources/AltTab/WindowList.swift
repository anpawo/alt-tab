import AppKit
// The sweep hands `AXUIElement`s across threads and merges into a shared dictionary, neither of
// which the compiler can see is safe. Both are, and deliberately: an AX element is a CF object
// with no Swift-visible state, an AX call against *another* process is Mach IPC and belongs off
// the main thread, and every touch of the shared dictionary below is inside an explicit lock.
// The one rule that would be unsafe — AX against our *own* process off-main — cannot happen
// here, because our own pid is filtered out before the sweep starts.
@preconcurrency import ApplicationServices
import SwitchCore

/// Building the list, Accessibility first.
///
/// The order is the one thing here that is not obvious. `CGWindowListCopyWindowInfo` is the
/// cheap, complete, permission-free half — it gives ids, owners and, within layer 0,
/// front-to-back order, which *is* the most-recently-used order. What it cannot give is a
/// handle you can act on. So it decides which windows exist and in what order, and
/// Accessibility is asked only about the ones that survived, for a title and an element.
///
/// Asking Accessibility only about apps that already own an on-screen layer-0 window is also
/// what keeps the sweep small: the average machine runs far more processes than it shows
/// windows.
enum WindowList {

    /// `_AXUIElementGetWindow` is the one private symbol in the app, and the only one there is
    /// no public substitute for: the Accessibility↔window-id bridge exists in this direction
    /// only. Loaded by `dlsym` rather than declared, so a macOS that renames it degrades the
    /// join to a title match instead of refusing to launch.
    private typealias GetWindow = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private static let getWindow: GetWindow? = {
        guard let h = dlopen("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices", RTLD_LAZY),
              let sym = dlsym(h, "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(sym, to: GetWindow.self)
    }()

    /// Which desktop a window is on, and which desktop you are looking at.
    ///
    /// Accessibility already answers only about the current Space, so for a while the filter was
    /// a side effect of that and of `.optionOnScreenOnly`. Neither is documented to mean "this
    /// desktop", and a rule that holds by coincidence is one that breaks without warning — an
    /// Android emulator sitting on its own Space is exactly the kind of window that turns up in
    /// a list it was never meant to be in. So the question is now asked out loud.
    ///
    /// Read-only calls, which is the safe half of this surface: reads on other applications'
    /// windows succeed, writes are silently refused to anyone but the Dock.
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SpacesForWindows = @convention(c) (Int32, UInt32, CFArray) -> Unmanaged<CFArray>?
    private typealias ActiveDisplay = @convention(c) (Int32) -> Unmanaged<CFString>?
    private typealias CurrentSpace = @convention(c) (Int32, CFString) -> UInt64

    private static let coreGraphics = dlopen(
        "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY)

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let coreGraphics, let sym = dlsym(coreGraphics, name) else { return nil }
        return unsafeBitCast(sym, to: T.self)
    }

    /// Loaded by name rather than declared, so a macOS that renames one of these degrades to
    /// "no Space filter" instead of refusing to launch.
    private static let mainConnection = symbol("CGSMainConnectionID", as: MainConnection.self)
    private static let spacesForWindows = symbol("CGSCopySpacesForWindows", as: SpacesForWindows.self)
    private static let activeDisplay = symbol("CGSCopyActiveMenuBarDisplayIdentifier", as: ActiveDisplay.self)
    private static let currentSpace = symbol("CGSManagedDisplayGetCurrentSpace", as: CurrentSpace.self)

    /// The windows, of those given, that are on the desktop currently being looked at.
    ///
    /// Returns everything when the Space cannot be determined: a filter that fails closed would
    /// empty the switcher, and a switcher showing one window too many still switches.
    private static func onCurrentSpace(_ ids: [CGWindowID]) -> Set<CGWindowID> {
        guard let mainConnection, let spacesForWindows, let activeDisplay, let currentSpace,
              !ids.isEmpty else { return Set(ids) }
        let connection = mainConnection()
        guard let display = activeDisplay(connection)?.takeRetainedValue() else { return Set(ids) }
        let here = currentSpace(connection, display)
        guard here != 0 else { return Set(ids) }

        var kept: Set<CGWindowID> = []
        for id in ids {
            let one = [NSNumber(value: id)] as CFArray
            // 0x7 asks for every kind of Space membership, so a window parked on a fullscreen
            // desktop answers as honestly as one on an ordinary desktop.
            guard let spaces = spacesForWindows(connection, 0x7, one)?.takeRetainedValue()
                    as? [NSNumber] else { continue }
            if spaces.contains(where: { $0.uint64Value == here }) { kept.insert(id) }
        }
        return kept
    }

    /// One element per process, kept alive for the life of the app.
    ///
    /// The warmth is in the mach port between the two processes, not in the object: a freshly
    /// created element after an idle period still costs a millisecond or two, while a
    /// connection that has been used once stays fast indefinitely. So this map exists to keep
    /// the process pair talking, and re-creating an element is not a way around a cold start.
    @MainActor private static var elements: [pid_t: AXUIElement] = [:]

    @MainActor
    private static func element(for pid: pid_t) -> AXUIElement {
        if let e = elements[pid] { return e }
        let e = AXUIElementCreateApplication(pid)
        // A stalled app costs exactly this timeout and then fails cleanly, so it is the single
        // number that bounds the whole sweep. The 6 s default is what turns one beachballing
        // app into a switcher that appears to be broken.
        AXUIElementSetMessagingTimeout(e, 0.05)
        elements[pid] = e
        return e
    }

    /// Pays the cold cost once, at login, instead of on the first ⌥Tab.
    @MainActor
    static func prewarm() {
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let e = element(for: app.processIdentifier)
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(e, kAXWindowsAttribute as CFString, &value)
        }
    }

    /// Anything not back within this budget is painted without its title. Warm, the whole
    /// sweep is a couple of milliseconds; this only ever fires when an app is wedged.
    private static let deadline = 0.030

    @MainActor
    static func snapshot() -> [WindowInfo] {
        let selfPID = getpid()

        // Z-order, front to back, layer 0 only. Everything above layer 0 is menu bar, Dock,
        // Control Center and wallpaper; everything below is Notification Center.
        var ordered: [(id: CGWindowID, pid: pid_t, size: CGSize)] = []
        if let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                 kCGNullWindowID) as? [[String: Any]] {
            for entry in list {
                guard entry[kCGWindowLayer as String] as? Int == 0,
                      let id = entry[kCGWindowNumber as String] as? CGWindowID,
                      let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                      Filter.isForeign(ownerPID: pid, selfPID: selfPID)
                else { continue }
                var size = CGSize.zero
                if let bounds = entry[kCGWindowBounds as String],
                   let rect = CGRect(dictionaryRepresentation: bounds as! CFDictionary) {
                    size = rect.size
                }
                ordered.append((id, pid, size))
            }
        }
        guard !ordered.isEmpty else { return [] }

        let here = onCurrentSpace(ordered.map(\.id))
        ordered.removeAll { !here.contains($0.id) }
        guard !ordered.isEmpty else { return [] }

        // Snapshot main-owned state before leaving the main thread.
        var names: [pid_t: String] = [:]
        var hidden: [pid_t: Bool] = [:]
        for app in NSWorkspace.shared.runningApplications {
            names[app.processIdentifier] = app.localizedName ?? "—"
            hidden[app.processIdentifier] = app.isHidden
        }
        // Every regular application, not only those holding an on-screen window: an app whose
        // windows are all minimized owns nothing that `CGWindowList` reports, and asking only
        // about the pids it named would be asking only about windows we can already see.
        // Our own pid is removed by hand — the CG loop above filters it, and nothing here would
        // while the settings window has us running as a regular app.
        var pids = Set(ordered.map(\.pid))
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            pids.insert(app.processIdentifier)
        }
        pids.remove(selfPID)
        let handles = pids.reduce(into: [pid_t: AXUIElement]()) { $0[$1] = element(for: $1) }

        // Concurrent, because a wedged app costs the timeout and serial sweeps make that
        // per-app instead of once.
        let lock = NSLock()
        var seen: [CGWindowID: (title: String, element: AXUIElement, minimized: Bool, size: CGSize, pid: pid_t)] = [:]
        // Which apps actually answered. An app that did not is not the same as an app with
        // nothing to show, and the two must not collapse: the first still owns windows the
        // user wants to reach, we just cannot name or address them.
        var answered: Set<pid_t> = []
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "alt-tab.ax", qos: .userInteractive, attributes: .concurrent)

        for (pid, app) in handles {
            let appHidden = hidden[pid] ?? false
            queue.async(group: group) {
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
                      let windows = value as? [AXUIElement] else { return }

                var found: [CGWindowID: (String, AXUIElement, Bool, CGSize, pid_t)] = [:]
                for window in windows {
                    guard let id = windowID(of: window) else { continue }
                    var subroleValue: CFTypeRef?
                    AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subroleValue)
                    var minimizedValue: CFTypeRef?
                    AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedValue)
                    let minimized = (minimizedValue as? Bool) ?? false
                    guard Filter.isSwitchable(subrole: subroleValue as? String,
                                              isMinimized: minimized,
                                              isAppHidden: appHidden) else { continue }

                    var titleValue: CFTypeRef?
                    AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue)
                    // Only windows off the screen need this: for the rest `CGWindowList` already
                    // gave a size, and this is an extra round trip per window.
                    var size = CGSize.zero
                    if minimized || appHidden {
                        var sizeValue: CFTypeRef?
                        if AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
                           let sizeValue, CFGetTypeID(sizeValue) == AXValueGetTypeID() {
                            AXValueGetValue(unsafeBitCast(sizeValue, to: AXValue.self), .cgSize, &size)
                        }
                    }
                    found[id] = ((titleValue as? String) ?? "", window, minimized, size, pid)
                }
                lock.lock()
                seen.merge(found) { a, _ in a }
                answered.insert(pid)
                lock.unlock()
            }
        }
        _ = group.wait(timeout: .now() + deadline)

        lock.lock()
        let resolved = seen
        let replied = answered
        lock.unlock()

        var rows: [WindowInfo] = ordered.compactMap { entry in
            let name = names[entry.pid] ?? "—"
            if let hit = resolved[entry.id] {
                // On screen and minimized at once is a contradiction the WindowServer briefly
                // allows, mid-animation. Accessibility is the one that knows, so it wins, and
                // the window is picked up by the pass below instead.
                guard !hit.minimized, hidden[entry.pid] != true else { return nil }
                return WindowInfo(id: entry.id, pid: entry.pid, appName: name,
                                  title: hit.title.isEmpty ? name : hit.title,
                                  element: hit.element, size: entry.size)
            }
            // Answered and not in the result: the subrole filter rejected it. Trust that.
            guard !replied.contains(entry.pid) else { return nil }
            // Never answered: keep the row. It is unfiltered and unnamed and can only be
            // raised at application granularity, which is still better than a window that
            // vanishes from the switcher because its app is busy.
            return WindowInfo(id: entry.id, pid: entry.pid, appName: name, title: name,
                              element: nil, size: entry.size)
        }

        // The windows that are not on the screen, after all of the ones that are. There is no
        // honest place for them among the rest: Z order is the most-recently-used order, and a
        // window in the Dock or behind a hidden application has no Z position at all — so they
        // go at the end, sorted by name rather than by whatever order a concurrent sweep
        // happened to finish in, which would reshuffle between two opens.
        let offscreen = resolved.filter { $0.value.minimized || hidden[$0.value.pid] == true }
        if !offscreen.isEmpty {
            let here = onCurrentSpace(Array(offscreen.keys))
            rows += offscreen
                .filter { here.contains($0.key) }
                .map { id, hit -> WindowInfo in
                    let name = names[hit.pid] ?? "—"
                    return WindowInfo(id: id, pid: hit.pid, appName: name,
                                      title: hit.title.isEmpty ? name : hit.title,
                                      element: hit.element, size: hit.size,
                                      isMinimized: hit.minimized,
                                      isAppHidden: hidden[hit.pid] == true)
                }
                .sorted { ($0.appName, $0.title, $0.id) < ($1.appName, $1.title, $1.id) }
        }
        return rows
    }

    /// The window a process currently considers focused, if it has one.
    ///
    /// One Accessibility round trip, on the element we already keep warm for that process, whose
    /// messaging timeout is 50 ms — so an application that has stopped answering costs that and
    /// no more.
    @MainActor
    static func focusedWindowID(of pid: pid_t) -> CGWindowID? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element(for: pid), kAXFocusedWindowAttribute as CFString,
                                            &value) == .success else { return nil }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return windowID(of: unsafeBitCast(value, to: AXUIElement.self))
    }

    private static func windowID(of element: AXUIElement) -> CGWindowID? {
        guard let getWindow else { return nil }
        var id: CGWindowID = 0
        return getWindow(element, &id) == .success ? id : nil
    }
}
