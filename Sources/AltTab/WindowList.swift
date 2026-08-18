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
        var ordered: [(id: CGWindowID, pid: pid_t)] = []
        if let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                 kCGNullWindowID) as? [[String: Any]] {
            for entry in list {
                guard entry[kCGWindowLayer as String] as? Int == 0,
                      let id = entry[kCGWindowNumber as String] as? CGWindowID,
                      let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                      Filter.isForeign(ownerPID: pid, selfPID: selfPID)
                else { continue }
                ordered.append((id, pid))
            }
        }
        guard !ordered.isEmpty else { return [] }

        // Snapshot main-owned state before leaving the main thread.
        var names: [pid_t: String] = [:]
        for app in NSWorkspace.shared.runningApplications {
            names[app.processIdentifier] = app.localizedName ?? "—"
        }
        let pids = Set(ordered.map(\.pid))
        let handles = pids.reduce(into: [pid_t: AXUIElement]()) { $0[$1] = element(for: $1) }

        // Concurrent, because a wedged app costs the timeout and serial sweeps make that
        // per-app instead of once.
        let lock = NSLock()
        var seen: [CGWindowID: (title: String, element: AXUIElement)] = [:]
        // Which apps actually answered. An app that did not is not the same as an app with
        // nothing to show, and the two must not collapse: the first still owns windows the
        // user wants to reach, we just cannot name or address them.
        var answered: Set<pid_t> = []
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "alt-tab.ax", qos: .userInteractive, attributes: .concurrent)

        for (pid, app) in handles {
            queue.async(group: group) {
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
                      let windows = value as? [AXUIElement] else { return }

                var found: [CGWindowID: (String, AXUIElement)] = [:]
                for window in windows {
                    guard let id = windowID(of: window) else { continue }
                    var subroleValue: CFTypeRef?
                    AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subroleValue)
                    var minimizedValue: CFTypeRef?
                    AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimizedValue)
                    guard Filter.isSwitchable(subrole: subroleValue as? String,
                                              isMinimized: (minimizedValue as? Bool) ?? false)
                    else { continue }

                    var titleValue: CFTypeRef?
                    AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue)
                    found[id] = ((titleValue as? String) ?? "", window)
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

        return ordered.compactMap { entry in
            let name = names[entry.pid] ?? "—"
            if let hit = resolved[entry.id] {
                return WindowInfo(id: entry.id, pid: entry.pid, appName: name,
                                 title: hit.title.isEmpty ? name : hit.title, element: hit.element)
            }
            // Answered and not in the result: the subrole filter rejected it. Trust that.
            guard !replied.contains(entry.pid) else { return nil }
            // Never answered: keep the row. It is unfiltered and unnamed and can only be
            // raised at application granularity, which is still better than a window that
            // vanishes from the switcher because its app is busy.
            return WindowInfo(id: entry.id, pid: entry.pid, appName: name, title: name, element: nil)
        }
    }

    private static func windowID(of element: AXUIElement) -> CGWindowID? {
        guard let getWindow else { return nil }
        var id: CGWindowID = 0
        return getWindow(element, &id) == .success ? id : nil
    }
}
