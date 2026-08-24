#!/bin/bash
# Build, sign, notarize and package Clio as a DMG anyone can run.
#
# build-app.sh already produces a correctly signed app; this adds the parts that
# only matter when the app leaves this Mac. A locally built app carries no
# quarantine flag, so Gatekeeper never checks it. A downloaded one does, and
# without notarization macOS refuses it outright — "Clio is damaged" — which
# looks like a broken build rather than a missing step.
#
# Nothing secret lives here. Credentials come from the keychain by name, so this
# file is safe to read, safe to commit, and safe to paste into a CI log:
#
#   NOTARY_PROFILE  name of a notarytool keychain profile (default: clio-notary),
#                   created once with:
#                     xcrun notarytool store-credentials clio-notary \
#                         --key AuthKey_XXXX.p8 --key-id KEYID --issuer ISSUER
#
# ALLOW_DIRTY=1 releases from an uncommitted tree. For trying this script out,
# not for anything anyone else will run.
set -euo pipefail
cd "$(dirname "$0")/.."

# The app was called Scribe until the rename, and the notarytool profile in the
# Keychain is still named for it. notarytool credentials cannot be renamed --
# storing them needs the App Store Connect key again -- so rather than break
# releasing over a name, fall back to the old profile and say so.
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
if [ -z "$NOTARY_PROFILE" ]; then
	if xcrun notarytool history --keychain-profile clio-notary >/dev/null 2>&1; then
		NOTARY_PROFILE="clio-notary"
	elif xcrun notarytool history --keychain-profile scribe-notary >/dev/null 2>&1; then
		NOTARY_PROFILE="scribe-notary"
		echo "note: using the legacy 'scribe-notary' keychain profile."
		echo "      To retire it, run once with your App Store Connect key:"
		echo "        xcrun notarytool store-credentials clio-notary \\"
		echo "            --key AuthKey_XXXX.p8 --key-id KEYID --issuer ISSUER"
	else
		echo "error: no notarytool keychain profile found (tried clio-notary," >&2
		echo "       scribe-notary). Create one with notarytool store-credentials." >&2
		exit 1
	fi
fi
echo "==> Notarizing with keychain profile: $NOTARY_PROFILE"

APP="Clio.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
BUILD_NUMBER="$(git rev-list --count HEAD)"
OUT="dist"
DMG="$OUT/Clio-$VERSION.dmg"

# Refuse to ship a dirty tree. A release nobody can check out again is not a
# release: the DMG would contain code that exists on exactly one machine.
if [ -z "${ALLOW_DIRTY:-}" ] && [ -n "$(git status --porcelain)" ]; then
	echo "error: working tree is dirty — commit or stash before releasing" >&2
	echo "       (ALLOW_DIRTY=1 to override, for testing this script)" >&2
	exit 1
fi

echo "==> Building Clio $VERSION ($BUILD_NUMBER)"
CLIO_BUILD_NUMBER="$BUILD_NUMBER" scripts/build-app.sh

# An ad-hoc signature cannot be notarized, and finding that out from Apple three
# minutes later is a worse way to learn it.
#
# Output captured before matching rather than piped into `grep -q`. Under
# `set -o pipefail` that pipeline is a race: grep exits on its first match and
# closes the pipe, codesign dies of SIGPIPE, and the pipeline reports failure —
# but only when codesign is the slower of the two, which is exactly what
# happens on a bundle large enough to be worth notarizing.
SIGNATURE="$(codesign -dvv "$APP" 2>&1 || true)"
if ! printf '%s\n' "$SIGNATURE" | grep -q "^TeamIdentifier=[A-Z0-9]"; then
	echo "error: $APP is not signed with a Developer ID — nothing to notarize" >&2
	exit 1
fi

mkdir -p "$OUT"
IDENTITY="$(security find-identity -v -p codesigning \
	| grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/')"

# The app is notarized and stapled BEFORE it goes in the DMG, and the DMG is
# notarized after. Two round trips, and both are needed.
#
# Stapling only the DMG looked like it worked -- Gatekeeper accepted the app
# inside it -- but `stapler validate` on that app said "does not have a ticket
# stapled to it". It passed because this Mac could reach Apple and check the
# record online. Copy the app out of the DMG, be offline on first launch, and
# the same bundle is "damaged". The ticket has to be in the app itself.
echo "==> Notarizing the app (this waits on Apple, typically a minute or two)"
ZIP="$OUT/Clio-$VERSION-app.zip"
rm -f "$ZIP"
# ditto, not zip: it preserves the symlinks and extended attributes a signed
# bundle is made of. A plain zip can invalidate the signature it is carrying.
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
rm -f "$ZIP"

xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "==> Packaging"
rm -f "$DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
# The drag-to-install target. Without it the DMG is a folder with an app in it
# and people run Clio from the disk image, where it cannot update itself.
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Clio $VERSION" -srcfolder "$STAGE" \
	-ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

codesign --force --timestamp --sign "$IDENTITY" "$DMG"

echo "==> Notarizing the disk image"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo "==> Verifying the way a downloader's Mac will"
spctl --assess --type open --context context:primary-signature -vv "$DMG"

echo
echo "Built $DMG"
echo "This is the artifact to publish. Do not ship $APP from the checkout —"
echo "it has no build number stamped and is not stapled."
