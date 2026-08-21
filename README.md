# alt-tab

A macOS window switcher that only switches windows. ⌥Tab, one Space, icons and titles.

macOS switches *applications*. ⌘Tab lands you on an app and leaves you to find which of its
six windows you meant. This switches windows: every window on the desktop you are looking at,
in most-recently-used order, with its own title and a picture of itself.

Hold ⌥ and press Tab. Let ⌥ go and you are there. That is the whole product.

**⌥Tab by default, and not ⌘Tab, on purpose.** The Dock consumes ⌘Tab before any application
sees it, so holding that chord means switching Apple's switcher off — and that setting outlives
the app that changed it. A default that did so would take the machine's switcher away from
someone who asked for nothing. So alt-tab starts on a chord nobody owns: both switchers are
there, you use one and then the other on the same desktop, and you decide.

If you decide on this one, **the settings will give you ⌘Tab**. alt-tab then switches the
system chord off while it holds it, and hands it back when you quit it or run `./uninstall.sh`.
If a crash ever leaves you without one, `alt-tab --restore-hotkeys` returns it, and it works
with no GUI at all.

## Install

**Download** the latest release, unzip it, and move `Alt-tab.app` to `~/Applications`.

macOS will refuse to open it the first time: the release is signed ad-hoc, which is what an
app signed by nobody looks like. **Right-click it → Open**, then confirm. You only do this
once.

Then open the app. It puts up its settings window, where you can tick **Start at login**.

**Or build it yourself**, which is the better option on your own machine — see below. A local
build can be signed with a certificate of your own, and macOS then keeps the Accessibility
grant across rebuilds instead of asking again every time.

```sh
git clone https://github.com/anpawo/alt-tab.git
cd alt-tab
./install.sh
```

`install.sh` builds the app, installs it to `~/Applications`, and registers a LaunchAgent so it
starts with your session.

## Permissions

Two, and the app is honest about both — the settings window says which are missing and takes
you to the right pane.

- **Accessibility** is required. Without it alt-tab can read no window titles and raise no
  windows, so the panel lists applications and does nothing when you let ⌥ go.
- **Screen Recording** is optional. Without it there are no pictures of windows, only
  application icons. Everything else works.

macOS answers the Screen Recording question once per launch, so pictures start appearing after
you quit and reopen the app — not the moment you grant it.

## Using it

| | |
|---|---|
| **⌥Tab** | open the switcher, and step through the windows — or whatever chord you bound |
| **let ⌥ go** | switch to the selected window |
| **Escape** | change your mind |
| **click a tile** | switch to that window — with ⌥ still held, since letting go ends the session |
| **click the red cross** | close that window |

A ⌥Tab faster than the panel's delay switches without drawing anything at all. The delay is a
slider in the settings; 100 ms by default, and 0 means the panel always appears.

Minimized windows, and the windows of hidden applications, are in the list — at the end, since
a window in the Dock has no place in a most-recently-used order. They carry a mark in their
title line and show the last picture taken of them, or the application's icon. Both kinds can
be switched off in the settings.

alt-tab has no Dock icon and no menu bar icon. Opening the application is what opens its
settings, and the ⇥ icon appears in the menu bar while that window is up. Tick the box to keep
it there.

## Building

```sh
python3 build.py                  # universal (Apple Silicon and Intel), into ./dist
python3 build.py --arch native    # only this machine's architecture — about twice as fast
python3 build.py --adhoc --zip    # what a downloadable release is made of
```

No dependencies beyond a Swift toolchain and the Command Line Tools; the script uses nothing
but the Python standard library, and it never touches the network.

Two things worth knowing.

**Universal builds are two builds.** Swift Package Manager can only produce more than one
architecture in a single pass through Xcode's XCBuild, which a machine with only the Command
Line Tools does not have. So `build.py` compiles each architecture separately and `lipo`s them
together. Use `--arch native` while you are working.

**The signature decides whether macOS remembers your permission.** The Accessibility grant is
tied to the signing identity. An ad-hoc signature has no identity — its fingerprint is a hash
of the binary — so every rebuild is a new app as far as macOS is concerned, and it asks again.
Run `./make-signing-identity.sh` once to create a local self-signed certificate; `build.py`
picks it up automatically from then on. Anything published has to be ad-hoc regardless, since
that certificate is trusted nowhere but here.

```sh
swift run check     # the test suite: the window filter, the state machine, the shortcut model
./uninstall.sh      # removes the app, the LaunchAgent and the log
```

## What it does not do

It switches windows on the desktop you are looking at. It does not do Spaces other than the
current one, applications without windows, alphabetical ordering, per-application rules,
searching, arrow keys, or a reverse shortcut. If you want those, [AltTab][alttab] has spent
years on them and does them well — this is the small version of that idea, built to be read
in an afternoon.

[alttab]: https://alt-tab-macos.netlify.app

## Licence

MIT.
