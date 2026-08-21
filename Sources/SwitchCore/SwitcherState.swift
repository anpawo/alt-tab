import CoreGraphics

/// What the trigger can say. Deliberately without an `.open` case: `.next` on an idle
/// machine opens, `.next` on an open one advances. All the state lives here, so the trigger
/// is stateless and cannot tell the first Tab from the third — which is what lets ⌥Tab and a
/// future ⌘Tab emit identical streams.
public enum SwitchCommand: Equatable {
    case next
    /// A window named outright rather than stepped to — the pointer clicking a tile. It commits
    /// in the same breath, because a click is the whole gesture and there is no modifier left
    /// to release afterwards.
    case pick(CGWindowID)
    case commit
    case cancel
    case abort
}

/// What the shell must do about it. `.raise` closes the panel and hands focus to the chosen
/// window; `.hide` closes it and gives focus back to where it came from. Cancel emits
/// `.hide`, never `.raise` — an invariant that holds whether or not the panel activates.
public enum Effect: Equatable {
    case show([WindowInfo], Int)
    case move(Int)
    case hide
    case raise(WindowInfo)
}

public struct SwitcherState {

    /// Selection is a window id, never an index. An index goes stale the moment the list
    /// moves under it, and then the *default* pick silently re-derives while the *user's*
    /// pick does not — which is the shape of the bug, not a crash.
    private var selected: CGWindowID?
    /// Where the selection sat before the list changed, so a closed window hands its place to
    /// the one that takes it rather than sending the selection back to the start.
    private var previousIndex = 0

    public init() {}

    public var isOpen: Bool { selected != nil }

    /// Re-states the panel over a list that has changed underneath it — a window closed, or
    /// simply gone.
    ///
    /// The selection is kept by identity when the window is still there and falls back to the
    /// same position otherwise, which is what makes closing several in a row feel like a list
    /// and not like a reset.
    public mutating func refresh(_ windows: [WindowInfo]) -> Effect? {
        guard let current = selected else { return nil }
        guard !windows.isEmpty else {
            selected = nil
            return .hide
        }
        if let index = windows.firstIndex(where: { $0.id == current }) {
            return .show(windows, index)
        }
        let index = min(previousIndex, windows.count - 1)
        selected = windows[index].id
        return .show(windows, index)
    }

    public mutating func handle(_ command: SwitchCommand, windows: [WindowInfo]) -> Effect? {
        switch command {
        case .next:
            guard !windows.isEmpty else { return nil }
            guard let current = selected else {
                // Opening. Landing on index 1 is the product: one ⌥Tab goes to the window you
                // were on before this one, and a second brings you back.
                let start = min(1, windows.count - 1)
                selected = windows[start].id
                previousIndex = start
                return .show(windows, start)
            }
            let i = windows.firstIndex(where: { $0.id == current }) ?? 0
            let next = (i + 1) % windows.count
            selected = windows[next].id
            previousIndex = next
            return .move(next)

        case let .pick(id):
            // Unguarded by `isOpen`: a tile can only be clicked while the panel is up, and the
            // click is answered by the window it named, not by whatever the keyboard had.
            guard let window = windows.first(where: { $0.id == id }) else { return nil }
            selected = nil
            return .raise(window)

        case .commit:
            // A modifier released while nothing is open is the common case, not an error:
            // every ⌥ press in normal typing arrives here.
            guard let current = selected else { return nil }
            selected = nil
            guard let window = windows.first(where: { $0.id == current }) else { return .hide }
            return .raise(window)

        case .cancel, .abort:
            guard selected != nil else { return nil }
            selected = nil
            return .hide
        }
    }
}
