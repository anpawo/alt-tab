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
    private static var lastCapture: [CGWindowID: TimeInterval] = [:]

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

    /// Photographs a window while it is the one being used, so that it already has a picture by
    /// the time it is a row in the switcher.
    ///
    /// This is where the pictures actually come from in practice. Capturing only when the panel
    /// opens means the first ⌥Tab of a session shows icons and fills in behind itself, every
    /// time; capturing on focus means the panel is usually complete before it appears.
    ///
    /// Never while the panel is up — that is the caller's guarantee — and at most once every
    /// 800 ms per window, because focus changes come in bursts and a capture is 45–50 ms of
    /// somebody else's machine.
    static func captureFocused(of pid: pid_t) {
        guard isPermitted, let id = WindowList.focusedWindowID(of: pid) else { return }
        captureSoon(id)
    }

    /// The same, for a window we already know the identity of — after raising one ourselves,
    /// where asking who has focus would answer about the moment before the raise.
    static func captureSoon(_ id: CGWindowID) {
        guard isPermitted else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if let last = lastCapture[id], now - last < 0.8 { return }
        lastCapture[id] = now
        // A moment for the window to finish arriving. Captured on the notification itself it
        // comes back mid-animation, half-drawn and half-transparent, and that is the picture
        // that would then be cached for as long as the window stays in the background.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { captureQuietly([id]) }
    }

    /// Fills the cache without claiming a round. The panel filters what it accepts by round, so
    /// a background capture must not take one — it would silently invalidate the pictures of a
    /// panel that is open at the time.
    static func captureQuietly(_ ids: [CGWindowID]) {
        run(ids, round: nil, onImage: { _, _, _ in })
    }

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
                lastCapture = lastCapture.filter { known[$0.key] != nil }
            }
        }
    }

    /// Captures the given windows, newest picture wins, calling back on the main thread as each
    /// one lands. `onImage` is only worth acting on while the same panel is still up — the
    /// generation it is handed says which.
    /// Returns the round it claimed, so the caller can compare rather than keeping a second
    /// counter in step with this one by hand.
    @discardableResult
    static func capture(_ ids: [CGWindowID], onImage: @escaping (CGWindowID, NSImage, Int) -> Void) -> Int {
        generation += 1
        run(ids, round: generation, onImage: onImage)
        return generation
    }

    private static func run(_ ids: [CGWindowID], round: Int?,
                            onImage: @escaping (CGWindowID, NSImage, Int) -> Void) {
        guard isPermitted else { return }
        let round = round ?? -1
        let wanted = ids
        let pixels = size
        // Retina, and not read from a screen because the capture runs off the main thread. Two
        // is what every display this will run on uses; being wrong costs sharpness, not
        // correctness.
        let scale: CGFloat = 2
        Task {
            var targets = await MainActor.run { wanted.compactMap { id in known[id].map { (id, $0) } } }
            // A window opened since the last refresh is not in the warm list, which is exactly
            // the window most likely to be asked about. Refreshing here and carrying on costs
            // this one pass and heals the list; refreshing "for next time" means a window that
            // has never been photographed never is.
            if targets.count != wanted.count,
               let content = try? await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: true) {
                targets = await MainActor.run {
                    known = Dictionary(content.windows.map { ($0.windowID, $0) },
                                       uniquingKeysWith: { a, _ in a })
                    return wanted.compactMap { id in known[id].map { (id, $0) } }
                }
            }
            guard !targets.isEmpty else { return }

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
                            // Asked for at the window's own shape, not at a fixed one. Given a
                            // frame it does not fit, ScreenCaptureKit letterboxes — and the bars
                            // it adds are not transparent, so a tall window came back as a strip
                            // of picture in a slab of black, sitting wherever the padding put it.
                            // Matching the ratio means there is nothing to pad and nothing to
                            // align: a narrow window is simply a narrow image, which the tile
                            // then centres.
                            //
                            // Never enlarged past its own size either — a small window blown up
                            // to fill a tile is a blurred small window.
                            let frame = window.frame
                            guard frame.width > 0, frame.height > 0 else { return nil }
                            let fit = min(pixels.width / frame.width, pixels.height / frame.height, 1)
                            let logical = CGSize(width: (frame.width * fit).rounded(),
                                                 height: (frame.height * fit).rounded())
                            guard logical.width >= 1, logical.height >= 1 else { return nil }

                            let configuration = SCStreamConfiguration()
                            configuration.width = Int(logical.width * scale)
                            configuration.height = Int(logical.height * scale)
                            configuration.showsCursor = false
                            configuration.ignoreShadowsSingleWindow = true

                            let filter = SCContentFilter(desktopIndependentWindow: window)
                            guard let image = try? await SCScreenshotManager.captureImage(
                                contentFilter: filter, configuration: configuration) else { return nil }
                            return (id, NSImage(cgImage: image, size: logical))
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
