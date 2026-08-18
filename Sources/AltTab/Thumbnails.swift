import AppKit
import ScreenCaptureKit

/// Pictures of the windows themselves.
///
/// Everything here is off the show path, because none of it is fast enough to be on it.
/// Measured on this machine: one `SCScreenshotManager` capture is 45–50 ms **whatever size you
/// ask for** — the cost is the round trip, not the pixels — and `SCShareableContent` is 32–115 ms
/// with outliers past 200. So the panel opens on icons and the pictures arrive into it.
///
/// The window list is kept warm rather than fetched per open, and captures run in small batches:
/// an unbounded burst does not go faster, it wedges the system screenshot service for everyone.
@MainActor
enum Thumbnails {

    /// Enough to look at, small enough that thirty of them are not a memory problem. Asking the
    /// API for this size rather than shrinking a full-resolution capture afterwards is the
    /// difference between about 1.6 MB and 37 MB per window.
    static let size = CGSize(width: 176, height: 110)

    private static var cache: [CGWindowID: NSImage] = [:]
    private static var known: [CGWindowID: SCWindow] = [:]
    private static var refreshing = false
    private static var generation = 0

    /// A grant we can check but must not act on before it exists: the answer is latched for the
    /// life of the process, so a "no" stays "no" until the next launch however long the user
    /// takes in System Settings.
    static var isPermitted: Bool { CGPreflightScreenCaptureAccess() }

    static func requestAccess() {
        // Puts the prompt up and returns immediately. Nothing here can use the answer before a
        // restart, which is why the panel says so rather than waiting.
        _ = CGRequestScreenCaptureAccess()
    }

    static func cached(_ id: CGWindowID) -> NSImage? { cache[id] }

    /// Refreshes the list of capturable windows without blocking anything.
    static func warm() {
        guard isPermitted, !refreshing else { return }
        refreshing = true
        Task {
            let content = try? await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
            await MainActor.run {
                refreshing = false
                guard let content else { return }
                known = Dictionary(content.windows.map { ($0.windowID, $0) },
                                   uniquingKeysWith: { a, _ in a })
                // Window ids are recycled, so a picture kept for an id nobody reports any more
                // would eventually be shown for a different window entirely.
                cache = cache.filter { known[$0.key] != nil }
            }
        }
    }

    /// Captures the given windows, newest picture wins, calling back on the main thread as each
    /// one lands. `onImage` is only worth acting on while the same panel is still up — the
    /// generation it is handed says which.
    static func capture(_ ids: [CGWindowID], onImage: @escaping (CGWindowID, NSImage, Int) -> Void) {
        guard isPermitted else { return }
        generation += 1
        let round = generation
        let targets = ids.compactMap { id in known[id].map { (id, $0) } }
        // Anything we have no handle for means the warm list is stale — refresh it for next time
        // rather than paying for it now.
        if targets.count != ids.count { warm() }
        guard !targets.isEmpty else { return }

        let pixels = size
        Task {
            let configuration = SCStreamConfiguration()
            configuration.width = Int(pixels.width * 2)
            configuration.height = Int(pixels.height * 2)
            configuration.showsCursor = false
            configuration.ignoreShadowsSingleWindow = true

            // Six at a time. Concurrency helps up to a point and then hurts: replayd serialises
            // internally, and a burst of a dozen has been measured to take longer in total than
            // the same dozen run in sequence, while blocking every other screenshot on the
            // machine for seconds.
            for batch in stride(from: 0, to: targets.count, by: 6).map({
                Array(targets[$0..<min($0 + 6, targets.count)])
            }) {
                await withTaskGroup(of: (CGWindowID, NSImage)?.self) { group in
                    for (id, window) in batch {
                        group.addTask {
                            let filter = SCContentFilter(desktopIndependentWindow: window)
                            guard let image = try? await SCScreenshotManager.captureImage(
                                contentFilter: filter, configuration: configuration) else { return nil }
                            return (id, NSImage(cgImage: image, size: pixels))
                        }
                    }
                    for await result in group {
                        guard let (id, image) = result else { continue }
                        await MainActor.run {
                            cache[id] = image
                            onImage(id, image, round)
                        }
                    }
                }
            }
        }
    }
}
