#!/bin/bash
# Produce the appcast that tells installed copies of Clio an update exists.
#
# Sparkle's generate_appcast reads a directory of built updates, signs each one
# with the EdDSA private key in the Keychain, and writes the XML. The private
# key never leaves the Keychain and never appears in the output.
#
# The flow, once per release:
#
#   1. scripts/release.sh                  -> dist/Clio-<version>.dmg
#   2. scripts/generate-appcast.sh         -> dist/appcast.xml
#   3. Create a GitHub release tagged v<version> on petit-software/clio and
#      attach the DMG to it. The download URL below has to match.
#   4. Copy dist/appcast.xml to docs/appcast.xml here and push. GitHub Pages
#      serves this repo's docs/ at /clio/, which is where SUFeedURL points.
#
# Step 3 before step 4: an appcast that points at a download which does not
# exist yet turns every running copy's update check into a failure.
set -euo pipefail
cd "$(dirname "$0")/.."

UPDATES_DIR="${1:-dist}"
REPO="petit-software/clio"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
TAG="v$VERSION"

TOOL="$(find .build/artifacts -name generate_appcast -type f 2>/dev/null | head -1)"
if [ -z "$TOOL" ]; then
	echo "error: Sparkle's generate_appcast not found — run 'swift build' first" >&2
	exit 69
fi

if [ ! -d "$UPDATES_DIR" ]; then
	echo "error: no updates directory at $UPDATES_DIR — run scripts/release.sh first" >&2
	exit 66
fi

if ! ls "$UPDATES_DIR"/*.dmg >/dev/null 2>&1; then
	echo "error: no .dmg in $UPDATES_DIR — run scripts/release.sh first" >&2
	exit 66
fi

# The key that must match SUPublicEDKey in Info.plist. Checked here rather than
# discovered by a user whose update silently refuses to install.
EXPECTED="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' Resources/Info.plist)"
KEYTOOL="$(find .build/artifacts -name generate_keys -type f | head -1)"
ACTUAL="$("$KEYTOOL" -p 2>/dev/null || true)"
if [ -n "$ACTUAL" ] && [ "$ACTUAL" != "$EXPECTED" ]; then
	echo "error: the Keychain's signing key does not match SUPublicEDKey" >&2
	echo "       Info.plist expects: $EXPECTED" >&2
	echo "       Keychain holds:     $ACTUAL" >&2
	echo "       Updates signed with this key would be rejected by every" >&2
	echo "       installed copy of Clio." >&2
	exit 1
fi

# Only this version's disk image is fed to the generator.
#
# --download-url-prefix is a single prefix applied to every item, and GitHub
# puts each release's assets under its own tag. Hand the generator a directory
# holding two versions and the older one is written with this version's tag in
# its URL -- a download that 404s, offered to exactly the users furthest behind.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp "$UPDATES_DIR/Clio-$VERSION.dmg" "$STAGE/" 2>/dev/null || {
	echo "error: $UPDATES_DIR/Clio-$VERSION.dmg not found — run scripts/release.sh" >&2
	exit 66
}

OTHERS="$(ls "$UPDATES_DIR"/*.dmg 2>/dev/null | grep -cv "Clio-$VERSION.dmg" || true)"
if [ "$OTHERS" -gt 0 ]; then
	echo "note: ignoring $OTHERS disk image(s) for other versions in $UPDATES_DIR."
	echo "      Sparkle only needs the newest; older items would be written with"
	echo "      this release's tag in their download URL."
fi

echo "==> Signing Clio $VERSION and writing the appcast"
"$TOOL" \
	--download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
	--link "https://github.com/$REPO/releases" \
	-o "$UPDATES_DIR/appcast.xml" \
	"$STAGE"

echo
echo "Wrote $UPDATES_DIR/appcast.xml"
echo
echo "Next, in that order:"
echo "  1. Create release $TAG on https://github.com/$REPO/releases/new"
echo "     and attach $UPDATES_DIR/Clio-$VERSION.dmg"
echo "  2. cp $UPDATES_DIR/appcast.xml docs/appcast.xml && git add docs/appcast.xml && git push"
echo
echo "Publishing the appcast before the download exists makes every running"
echo "copy's update check fail."
