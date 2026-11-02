#!/bin/bash
# Records the SDK a Clio binary was actually built with.
#
#   scripts/declare-sdk.sh <binary>
#
# SwiftPM links with the right SDK but writes the deployment target into the
# binary as its SDK version (LC_BUILD_VERSION sdk 14.0). macOS reads that
# number to decide whether an app was built for the current design, and below
# 26 it draws every system control the old way — no Liquid Glass in toolbars,
# sidebars, buttons or segmented controls, however the code asks for them.
# This writes the real SDK version in its place. The binary's signature is
# invalid afterwards: run it before signing (build-app.sh does), or sign it
# ad hoc for a debug binary, as below.
set -euo pipefail

binary="$1"
minimum="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' \
	"$(dirname "$0")/../Resources/Info.plist")"
sdk="$(xcrun --show-sdk-version)"

vtool -set-build-version macos "$minimum" "$sdk" -replace \
	-output "$binary.sdk" "$binary" 2>/dev/null
mv "$binary.sdk" "$binary"
chmod +x "$binary"

if [[ "${2:-}" == "--sign-ad-hoc" ]]; then
	codesign --force --sign - "$binary" >/dev/null 2>&1
fi
echo "$binary: built for macOS $minimum, SDK $sdk"
