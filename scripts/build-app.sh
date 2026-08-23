#!/bin/bash
# Build Whisperbar.app from the current checkout.
#
# SwiftPM produces a bare executable, and a bare executable has no Info.plist —
# so it cannot own a bundle identifier, request the microphone, or hide its Dock
# icon. This wraps the binary in a bundle that can.
#
# Ad-hoc signed. Developer ID signing and notarization are Milestone 6.
#
# Note on permissions: an ad-hoc signature changes every rebuild, so macOS treats
# each build as a new app and Accessibility has to be re-granted. That stops once
# the app is signed with a stable Developer ID identity.
set -euo pipefail

cd "$(dirname "$0")/.."
APP="Whisperbar.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"

echo "Building Whisperbar $VERSION — release…"
swift build -c release --product Whisperbar

mkdir -p "$APP/Contents/MacOS"
# Rebuilt from scratch so a renamed or dropped resource cannot linger.
rm -rf "$APP/Contents/Resources"
mkdir -p "$APP/Contents/Resources"

cp Resources/Info.plist "$APP/Contents/Info.plist"

# Copied to a temp name and moved into place: replacing the binary of a RUNNING
# app in place fails, and a half-written executable is worse than an old one.
cp ".build/release/Whisperbar" "$APP/Contents/MacOS/Whisperbar.new"
mv "$APP/Contents/MacOS/Whisperbar.new" "$APP/Contents/MacOS/Whisperbar"

codesign --force --sign - \
	--entitlements Resources/Whisperbar.entitlements \
	--options runtime \
	"$APP" 2>/dev/null || codesign --force --sign - \
	--entitlements Resources/Whisperbar.entitlements \
	"$APP"

echo "Built $APP"
