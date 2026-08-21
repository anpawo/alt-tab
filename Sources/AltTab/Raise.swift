import AppKit
import ApplicationServices
import SwitchCore

/// What we do to a window: bring it forward, or close it.
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
enum WindowAction {

    /// Presses the window's own close button, through Accessibility.
    ///
    /// Nothing is removed from the list here. A window closes when the system says it has, not
    /// when we asked — a document with unsaved changes puts up a sheet and stays exactly where
    /// it was, and a list that had already dropped it would be lying.
    @discardableResult
    static func close(_ window: WindowInfo) -> Bool {
        guard trusted(), let element = window.element else { return false }
        var button: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString,
                                            &button) == .success,
              CFGetTypeID(button) == AXUIElementGetTypeID() else { return false }
        return AXUIElementPerformAction(unsafeBitCast(button, to: AXUIElement.self),
                                        kAXPressAction as CFString) == .success
    }

    static func perform(_ window: WindowInfo) -> Bool {
        guard trusted() else { return false }

        let app = NSRunningApplication(processIdentifier: window.pid)
        guard let element = window.element else {
            // The app never answered Accessibility in time, so there is no handle to the
            // window itself. Its application can still be brought forward.
            return app?.activate() ?? false
        }
        // Putting the window back on the screen first, because `AXRaise` on one that is not
        // there is answered with success and does nothing. The two absences are undone by
        // different calls: un-hiding is about the application, un-minimizing about the window,
        // and a hidden application's minimized window needs both.
        if window.isAppHidden { app?.unhide() }
        if window.isMinimized {
            AXUIElementSetAttributeValue(element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
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
