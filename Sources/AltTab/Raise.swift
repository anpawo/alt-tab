import AppKit
import ApplicationServices
import SwitchCore

/// Handing focus to the chosen window.
///
/// `AXRaise` is the gesture macOS honours by following the window to wherever it lives —
/// activating the application alone only makes it frontmost, and if its window is on another
/// desktop you stay exactly where you are while the switcher appears to have done nothing.
/// The activation that follows is what makes the raised window key.
///
/// Both steps need the Accessibility grant, and this is where it is asked for: at the moment
/// the intent is legible, not at launch where a background agent asking for control of the
/// computer reads as an intrusion.
@MainActor
enum Raise {

    static func perform(_ window: WindowInfo) -> Bool {
        guard trusted() else { return false }

        let app = NSRunningApplication(processIdentifier: window.pid)
        guard let element = window.element else {
            // The app never answered Accessibility in time, so there is no handle to the
            // window itself. Its application can still be brought forward.
            return app?.activate() ?? false
        }
        let raised = AXUIElementPerformAction(element, kAXRaiseAction as CFString) == .success
        app?.activate()
        return raised
    }

    @discardableResult
    static func trusted() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}
