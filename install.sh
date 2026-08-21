#!/usr/bin/env bash
# Builds, installs to ~/Applications, and registers a LaunchAgent so alt-tab starts at login.
set -euo pipefail

cd "$(dirname "$0")"

LABEL="com.mr.alttab"
DEST="$HOME/Applications/Alt-tab.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

# The one build path; --arch native because this machine is the only one that will run it.
python3 build.py --arch native

echo "==> Installing to $DEST"
mkdir -p "$HOME/Applications"
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
rm -rf "$DEST"
cp -R dist/Alt-tab.app "$DEST"

echo "==> Writing $PLIST"
mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>$LABEL</string>
	<key>ProgramArguments</key>
	<array>
		<string>$DEST/Contents/MacOS/alt-tab</string>
		<!-- Says who started us. Without it the copy launched at login cannot tell itself
		     apart from the one you double-clicked, and puts a settings window in your face
		     every time you log in. -->
		<string>--agent</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<!-- Restarted when it dies unexpectedly, left alone when it exits on purpose — which is
	     what it does when another copy already holds the single-instance lock, and what the
	     menu bar's Quit relies on. Plain KeepAlive would fight both. -->
	<key>KeepAlive</key>
	<dict>
		<key>SuccessfulExit</key>
		<false/>
	</dict>
	<!-- Without this, System Settings lists the login item under the developer's name
	     instead of the app's. -->
	<key>AssociatedBundleIdentifiers</key>
	<array>
		<string>$LABEL</string>
	</array>
	<!-- Interactive, not Background: launchd throttles CPU and I/O for background agents, and
	     this one has to paint a window between a key going down and the same key coming up. -->
	<key>ProcessType</key>
	<string>Interactive</string>
	<!-- Opts out of timer coalescing. Precision over battery, for the same reason. -->
	<key>LegacyTimers</key>
	<true/>
	<!-- Not /tmp: that is world-readable, and anything this process ever prints came from a
	     keyboard path. -->
	<key>StandardErrorPath</key>
	<string>$HOME/Library/Logs/alt-tab.log</string>
</dict>
</plist>
PLIST_EOF
chmod 600 "$PLIST"

echo "==> Starting"
launchctl bootstrap "gui/$UID" "$PLIST"
launchctl kickstart -k "gui/$UID/$LABEL"

echo
echo "Installed, and invisible: no Dock icon and nothing in the menu bar."
echo
echo "Hold ⌥ and press Tab to switch windows; Escape cancels. With ⌥ still held,"
echo "click a tile to switch to it, or the red cross on its picture to close it."
echo "⌥Tab rather than ⌘Tab so the system switcher is still there to compare with;"
echo "open the app to change it, and for everything else it can be told to do."
echo
echo "The first time you commit a switch, macOS will ask for Accessibility."
echo "Until it is granted the panel lists applications without window names,"
echo "and cannot raise anything: System Settings → Privacy & Security → Accessibility."
echo
echo "  See what it sees:  $DEST/Contents/MacOS/alt-tab --render"
echo "  Logs:              ~/Library/Logs/alt-tab.log"
echo "  Uninstall:         ./uninstall.sh"
