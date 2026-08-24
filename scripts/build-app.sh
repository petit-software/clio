#!/bin/bash
# Build Clio.app from the current checkout.
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
APP="Clio.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"

echo "Building Clio $VERSION — release…"
swift build -c release --product Clio

mkdir -p "$APP/Contents/MacOS"
# Rebuilt from scratch so a renamed or dropped resource cannot linger.
rm -rf "$APP/Contents/Resources"
mkdir -p "$APP/Contents/Resources"

cp Resources/Info.plist "$APP/Contents/Info.plist"
# The model catalog. Read through Bundle.main, so it belongs in Contents/
# Resources -- see the comment in ModelCatalog.swift for why this is not a
# SwiftPM resource bundle.
cp Resources/models.json "$APP/Contents/Resources/models.json"

# Stamped before signing, since editing Info.plist afterwards would invalidate
# the signature. Dev builds stay at whatever the tracked plist says; release.sh
# passes the commit count so every shipped build has a distinct number.
if [ -n "${CLIO_BUILD_NUMBER:-}" ]; then
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $CLIO_BUILD_NUMBER" \
		"$APP/Contents/Info.plist"
fi

# Copied to a temp name and moved into place: replacing the binary of a RUNNING
# app in place fails, and a half-written executable is worse than an old one.
cp ".build/release/Clio" "$APP/Contents/MacOS/Clio.new"
mv "$APP/Contents/MacOS/Clio.new" "$APP/Contents/MacOS/Clio"

# --- Sparkle ----------------------------------------------------------------
# SwiftPM links Sparkle but does not embed it: a bare executable has nowhere to
# embed it TO. The framework has to travel inside the bundle, and the executable
# needs an rpath that finds it there -- without one the app launches only on a
# machine that happens to have Sparkle lying around.
SPARKLE="$(find .build/artifacts -name Sparkle.framework -maxdepth 6 -type d | head -1)"
if [ -z "$SPARKLE" ]; then
	echo "error: Sparkle.framework not found — run 'swift build' first" >&2
	exit 1
fi

rm -rf "$APP/Contents/Frameworks"
mkdir -p "$APP/Contents/Frameworks"
# -R preserves the framework's internal symlinks. Copying it flat produces a
# bundle that fails to load with an error naming a path that plainly exists.
cp -R "$SPARKLE" "$APP/Contents/Frameworks/"

# add_rpath errors rather than no-ops on a duplicate, and the binary is fresh
# each build, so this is unconditional but checked.
# Captured before matching, not piped into `grep -q` — see the note in
# release.sh about pipefail and SIGPIPE.
LOAD_COMMANDS="$(otool -l "$APP/Contents/MacOS/Clio" || true)"
if ! printf '%s\n' "$LOAD_COMMANDS" | grep -q "@executable_path/../Frameworks"; then
	install_name_tool -add_rpath "@executable_path/../Frameworks" \
		"$APP/Contents/MacOS/Clio"
fi

# The first Developer ID Application identity in the keychain. Matching on the
# prefix rather than a hardcoded hash so this survives a certificate renewal.
IDENTITY=""
if [ -z "${CLIO_ADHOC:-}" ]; then
	IDENTITY="$(security find-identity -v -p codesigning \
		| grep "Developer ID Application" \
		| head -1 \
		| sed -E 's/.*"(.*)"/\1/')"
fi

if [ -n "$IDENTITY" ]; then
	echo "Signing as: $IDENTITY"
	# --timestamp is what notarization requires later; it needs the network.
	# CLIO_NO_TIMESTAMP=1 skips it for building on a plane.
	TIMESTAMP="--timestamp"
	[ -n "${CLIO_NO_TIMESTAMP:-}" ] && TIMESTAMP="--timestamp=none"
	SIGN=("$IDENTITY")
else
	echo "No Developer ID identity found — signing ad-hoc."
	echo "Accessibility will need re-granting after every build."
	TIMESTAMP="--timestamp=none"
	SIGN=("-")
fi

# Inner code FIRST. A signature over a bundle is a signature over what it
# contained at the time, so sealing the app before its framework leaves the
# app's seal describing something that is no longer there.
#
# Sparkle ships helper apps and an XPC service inside its framework, each of
# which is its own signed bundle. --deep is deprecated for signing, so they are
# named explicitly: a missed one fails notarization rather than the build, which
# is a slow way to find out.
while IFS= read -r nested; do
	codesign --force --sign "${SIGN[@]}" --options runtime $TIMESTAMP "$nested"
done < <(find "$APP/Contents/Frameworks/Sparkle.framework" \
	\( -name "*.app" -o -name "*.xpc" \) -maxdepth 4 | sort -r)

codesign --force --sign "${SIGN[@]}" --options runtime $TIMESTAMP \
	"$APP/Contents/Frameworks/Sparkle.framework"

codesign --force --sign "${SIGN[@]}" \
	--entitlements Resources/Clio.entitlements \
	--options runtime \
	$TIMESTAMP \
	"$APP"

# A signature that does not verify is worse than none: the app launches until
# something checks it, then fails somewhere far from here.
codesign --verify --deep --strict --verbose=1 "$APP"

echo "Built $APP"
# The line worth seeing: with a Developer ID it names the bundle id and team,
# with an ad-hoc signature it is a cdhash that changes on every build.
codesign -d -r- "$APP" 2>&1 | grep 'designated =>'
