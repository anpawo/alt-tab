#!/usr/bin/env bash
# Builds Alt-tab.app into ./dist
set -euo pipefail

cd "$(dirname "$0")"
APP="dist/Alt-tab.app"

# A stray log call in the key-handling path is a plaintext keylog, and the launch agent below
# writes stderr to a file. Cheaper to make it un-shippable than to remember.
if grep -nE '\b(NSLog|print|os_log)\b' Sources/AltTab/Trigger.swift; then
	echo "error: no logging in the key-handling path" >&2
	exit 1
fi

echo "==> Checks"
swift run -c release check

echo "==> Compiling (release)"
swift build -c release --product alt-tab

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/alt-tab "$APP/Contents/MacOS/alt-tab"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# macOS ties the Accessibility grant to the signing identity, so the signature has to survive a
# rebuild or the permission is asked for again every time. Ad-hoc cannot: it has no identity,
# its fingerprint is a hash of the binary itself. Create the certificate once with
# ./make-signing-identity.sh; without it this still builds and runs, it just re-asks.
IDENTITY="Alt-tab Self-Signed"
INSTALLED="$(security find-identity -v -p codesigning || true)"
if [[ "$INSTALLED" == *"$IDENTITY"* ]]; then
	codesign --force --sign "$IDENTITY" "$APP"
else
	echo "==> No \"$IDENTITY\" certificate — signing ad-hoc (permissions will reset on each build)"
	codesign --force --sign - "$APP"
fi

echo "==> $APP"
