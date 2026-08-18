#!/usr/bin/env bash
set -euo pipefail
LABEL="com.mr.alttab"
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Applications/Alt-tab.app"
echo "Removed. alt-tab never disabled the system ⌘Tab, so there is nothing to restore —"
echo "but if another switcher left yours dead: alt-tab --restore-hotkeys"
