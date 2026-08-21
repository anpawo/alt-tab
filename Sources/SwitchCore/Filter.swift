import ApplicationServices

/// What counts as a switchable window.
///
/// Pure, and the only logic in the app that genuinely deserves tests: it is where every
/// "why is that thing in my list" bug lives.
public enum Filter {

    /// `AXStandardWindow` is the whole filter, and it is free — it rides on the same
    /// Accessibility round trip that already fetches the title.
    ///
    /// An area floor was tried first and measured useless: the junk that survives it is a
    /// swarm of full-width 1470×33 surfaces well above any floor worth setting, while a
    /// genuinely small utility window falls under it.
    /// Leaving the screen changes a window's subrole. Minimized, or belonging to a hidden
    /// application, it answers `AXDialog` whatever it was while it was up — so a filter that
    /// asks only for `AXStandardWindow` cannot see either kind, which is why both looked
    /// structurally impossible to list rather than merely absent.
    ///
    /// `AXDialog` is accepted only on that evidence. A dialog that is genuinely on screen is
    /// neither minimized nor owned by a hidden app, so it is still refused.
    public static func isSwitchable(subrole: String?, isMinimized: Bool, isAppHidden: Bool) -> Bool {
        if subrole == kAXStandardWindowSubrole { return true }
        return (isMinimized || isAppHidden) && subrole == kAXDialogSubrole
    }

    /// Our own panel is a titled, layer-0, standard window, and the panel activates — so
    /// without this it enumerates itself, lands at index 0 as the frontmost window, and
    /// shifts every entry by one. That silently defeats "⌥Tab goes to the previous window",
    /// which is the entire product.
    public static func isForeign(ownerPID: pid_t, selfPID: pid_t) -> Bool {
        ownerPID != selfPID
    }
}
