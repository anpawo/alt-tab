import CoreGraphics

/// What the trigger can say. Deliberately without an `.open` case: `.next` on an idle
/// machine opens, `.next` on an open one advances. All the state lives here, so the trigger
/// is stateless and cannot tell the first Tab from the third — which is what lets ⌥Tab and a
/// future ⌘Tab emit identical streams.
public enum SwitchCommand {
    case next
    case previous
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

    public init() {}

    public var isOpen: Bool { selected != nil }

    public mutating func handle(_ command: SwitchCommand, windows: [WindowInfo]) -> Effect? {
        switch command {
        case .next, .previous:
            let forward = command == .next
            guard !windows.isEmpty else { return nil }
            guard let current = selected else {
                // Opening. Landing on index 1 is the product: one ⌥Tab goes to the window you
                // were on before this one, and a second brings you back.
                let start = forward ? min(1, windows.count - 1) : windows.count - 1
                selected = windows[start].id
                return .show(windows, start)
            }
            let i = windows.firstIndex(where: { $0.id == current }) ?? 0
            let next = forward
                ? (i + 1) % windows.count
                : (i - 1 + windows.count) % windows.count
            selected = windows[next].id
            return .move(next)

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
