#!/bin/bash
# Build Scribe.app from the current checkout.
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
APP="Scribe.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"

echo "Building Scribe $VERSION — release…"
swift build -c release --product Scribe

mkdir -p "$APP/Contents/MacOS"
# Rebuilt from scratch so a renamed or dropped resource cannot linger.
rm -rf "$APP/Contents/Resources"
mkdir -p "$APP/Contents/Resources"

cp Resources/Info.plist "$APP/Contents/Info.plist"
# The model catalog. Read through Bundle.main, so it belongs in Contents/
# Resources -- see the comment in ModelCatalog.swift for why this is not a
# SwiftPM resource bundle.
cp Resources/models.json "$APP/Contents/Resources/models.json"

# Copied to a temp name and moved into place: replacing the binary of a RUNNING
# app in place fails, and a half-written executable is worse than an old one.
cp ".build/release/Scribe" "$APP/Contents/MacOS/Scribe.new"
mv "$APP/Contents/MacOS/Scribe.new" "$APP/Contents/MacOS/Scribe"

codesign --force --sign - \
	--entitlements Resources/Scribe.entitlements \
	--options runtime \
	"$APP" 2>/dev/null || codesign --force --sign - \
	--entitlements Resources/Scribe.entitlements \
	"$APP"

echo "Built $APP"
