import ApplicationServices
import SwitchCore

// A test harness in twenty lines, because the alternative on this machine is a framework that
// exits 0 without running anything.
private var failures = 0
private var checks = 0

private func expect(_ condition: Bool, _ what: String, line: UInt = #line) {
    checks += 1
    guard !condition else { return }
    failures += 1
    print("  ✗ \(what)  (line \(line))")
}

private func scenario(_ name: String, _ body: () -> Void) {
    let before = failures
    body()
    print("\(failures == before ? "ok  " : "FAIL") \(name)")
}

private func windows(_ n: Int) -> [WindowInfo] {
    (0..<n).map {
        WindowInfo(id: CGWindowID($0 + 1), pid: 100, appName: "App\($0)", title: "Window \($0)", element: nil)
    }
}

// Assertions are behavioural, never positional. `index == 1` passes for a switcher that always
// lands on the same row no matter which window you were on, which is a broken switcher.

scenario("opening lands somewhere other than the window already in front") {
    let list = windows(3)
    var state = SwitcherState()
    guard case let .show(_, index)? = state.handle(.next, windows: list) else {
        return expect(false, "opening produced no panel")
    }
    // Mutation target 1: `.next` on idle 1 → 0.
    expect(list[index].id != list[0].id, "opened on the front window")
}

scenario("a second step moves on again") {
    let list = windows(3)
    var state = SwitcherState()
    guard case let .show(_, first)? = state.handle(.next, windows: list),
          case let .move(second)? = state.handle(.next, windows: list) else {
        return expect(false, "no movement")
    }
    expect(list[second].id != list[first].id, "selection did not move")
}

scenario("stepping past the end comes back to the start") {
    let list = windows(3)
    var state = SwitcherState()
    _ = state.handle(.next, windows: list)
    _ = state.handle(.next, windows: list)
    guard case let .move(index)? = state.handle(.next, windows: list) else {
        return expect(false, "no movement")
    }
    // Mutation target 2: (i+1) % n → min(i+1, n-1) leaves this stuck on the last row.
    expect(list[index].id == list[0].id, "did not wrap around")
}

scenario("going backwards from idle reaches the far end") {
    let list = windows(3)
    var state = SwitcherState()
    guard case let .show(_, index)? = state.handle(.previous, windows: list) else {
        return expect(false, "opening produced no panel")
    }
    expect(list[index].id == list[2].id, "did not open on the last window")
}

scenario("a single window is still selectable") {
    var state = SwitcherState()
    guard case let .show(_, index)? = state.handle(.next, windows: windows(1)) else {
        return expect(false, "opening produced no panel")
    }
    expect(index == 0, "single window not selected")
}

scenario("with nothing open there is nothing to switch to") {
    var state = SwitcherState()
    expect(state.handle(.next, windows: []) == nil, "opened on an empty list")
    expect(state.isOpen == false, "left itself open")
}

scenario("committing raises the window that was selected") {
    let list = windows(3)
    var state = SwitcherState()
    guard case let .show(_, index)? = state.handle(.next, windows: list),
          case let .raise(window)? = state.handle(.commit, windows: list) else {
        return expect(false, "commit did not raise")
    }
    expect(window.id == list[index].id, "raised the wrong window")
    expect(state.isOpen == false, "stayed open after committing")
}

scenario("cancelling never raises anything") {
    let list = windows(3)
    var state = SwitcherState()
    _ = state.handle(.next, windows: list)
    // Mutation target 4: `.cancel` emitting `.raise` turns Escape into a switch.
    expect(state.handle(.cancel, windows: list) == .hide, "cancel did not simply hide")
    expect(state.isOpen == false, "stayed open after cancelling")
}

scenario("a modifier released with nothing open does nothing at all") {
    // Every ⌥ press in ordinary typing arrives here.
    var state = SwitcherState()
    expect(state.handle(.commit, windows: windows(3)) == nil, "commit acted while closed")
    expect(state.handle(.cancel, windows: windows(3)) == nil, "cancel acted while closed")
}

scenario("a window that vanished between opening and committing is not raised") {
    let list = windows(3)
    var state = SwitcherState()
    _ = state.handle(.next, windows: list)
    // Selection is held as a window id, so a list that lost that window resolves to nothing
    // rather than raising whoever now occupies the index.
    expect(state.handle(.commit, windows: [list[0]]) == .hide, "raised a stale index")
}

scenario("only standard, non-minimized windows are offered") {
    expect(Filter.isSwitchable(subrole: kAXStandardWindowSubrole, isMinimized: false), "rejected a standard window")
    expect(!Filter.isSwitchable(subrole: kAXDialogSubrole, isMinimized: false), "accepted a dialog")
    expect(!Filter.isSwitchable(subrole: nil, isMinimized: false), "accepted a window with no subrole")
    expect(!Filter.isSwitchable(subrole: kAXStandardWindowSubrole, isMinimized: true), "accepted a minimized window")
}

scenario("our own panel is never in our own list") {
    // Mutation target 3: dropping this puts the activating panel at index 0 and shifts every
    // entry by one, which quietly defeats the whole product.
    expect(!Filter.isForeign(ownerPID: 42, selfPID: 42), "kept our own window")
    expect(Filter.isForeign(ownerPID: 43, selfPID: 42), "dropped somebody else's window")
}

private let tab: UInt16 = 48
private let escape: UInt16 = 53
private let backtick: UInt16 = 50

scenario("the modifier that commits is never shift") {
    // Shift is how you say "the other way", so a chord holding it would commit the moment you
    // reversed direction.
    expect(Shortcut(keyCode: tab, modifiers: [.option, .shift]).holdModifier == .option,
           "shift won over option")
    expect(Shortcut(keyCode: tab, modifiers: [.command, .shift]).holdModifier == .command,
           "shift won over command")
    expect(Shortcut(keyCode: tab, modifiers: .shift).holdModifier == nil,
           "shift alone was accepted as holdable")
}

scenario("a chord with nothing to hold is refused") {
    // Not a nicety: these are global hotkeys, so a bare key would be taken from every app.
    expect(!Shortcut(keyCode: tab, modifiers: []).isValid, "bare Tab was accepted")
    expect(!Shortcut(keyCode: tab, modifiers: .shift).isValid, "⇧Tab was accepted")
    expect(Shortcut(keyCode: tab, modifiers: .option).isValid, "⌥Tab was refused")
    expect(Shortcut(keyCode: escape, modifiers: .control).isValid, "⌃Esc was refused")
}

scenario("the chords macOS keeps for itself are recognised") {
    // Registering one of these succeeds and then never fires, which reads as our own bug.
    expect(Shortcut(keyCode: tab, modifiers: .command).isClaimedByMacOS, "⌘Tab not flagged")
    expect(Shortcut(keyCode: tab, modifiers: [.command, .shift]).isClaimedByMacOS, "⌘⇧Tab not flagged")
    expect(Shortcut(keyCode: backtick, modifiers: .command).isClaimedByMacOS, "⌘` not flagged")
    expect(!Shortcut(keyCode: tab, modifiers: .option).isClaimedByMacOS, "⌥Tab wrongly flagged")
    expect(!Shortcut(keyCode: tab, modifiers: [.command, .option]).isClaimedByMacOS,
           "⌥⌘Tab wrongly flagged — macOS only claims the plain and shifted forms")
}

scenario("chords are written the way macOS writes them") {
    expect(Shortcut(keyCode: tab, modifiers: .option).label == "⌥Tab", "⌥Tab mislabelled")
    // Apple's canonical order is ⌃⌥⇧⌘, whatever order they were pressed in.
    expect(Shortcut(keyCode: tab, modifiers: [.shift, .option]).label == "⌥⇧Tab", "⌥⇧Tab mislabelled")
    expect(Shortcut(keyCode: escape, modifiers: .option).label == "⌥Esc", "⌥Esc mislabelled")
    expect(Shortcut(keyCode: 12, modifiers: [.command, .control]).label == "⌃⌘Q", "⌃⌘Q mislabelled")
}

scenario("the defaults are the three documented chords") {
    expect(Binding.next.fallback.label == "⌥Tab", "default next changed")
    expect(Binding.previous.fallback.label == "⌥⇧Tab", "default previous changed")
    expect(Binding.cancel.fallback.label == "⌥Esc", "default cancel changed")
    expect(Binding.allCases.allSatisfy { $0.fallback.isValid && !$0.fallback.isClaimedByMacOS },
           "a default is unusable")
}

print("\n\(checks) checks, \(failures) failed")
exit(failures == 0 ? 0 : 1)
