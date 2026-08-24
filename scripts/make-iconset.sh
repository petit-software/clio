#!/bin/bash
# Build Clio.icns into $1 (the bundle's Resources directory).
#
# The source is Icon Composer's iOS export, which fills the whole canvas because
# iOS masks icons itself. macOS does not mask and expects the body inset on the
# 824/1024 grid, so every size is generated from a re-fitted master — see
# make-icon-master.swift for what "odd edges" looks like without it.
#
# An .icns carries exactly ONE icon. Appearance variants on macOS come from an
# Icon Composer .icon document, not an asset catalogue, so the dark and tinted
# exports are kept in Resources/Icon for when there is one to compile.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ICONSET="$WORK/Clio.iconset"
mkdir -p "$ICONSET"

swift scripts/make-icon-master.swift Resources/Icon/default.png "$WORK/master.png" >/dev/null

# Written out rather than looped over a "size name" string: `set -- $spec` relies
# on word splitting, which zsh does not do to unquoted expansions, so the same
# script produced one file called `icon_.png` depending on which shell ran it.
emit() { sips -z "$1" "$1" "$WORK/master.png" --out "$ICONSET/icon_$2.png" >/dev/null; }
emit 16   16x16
emit 32   16x16@2x
emit 32   32x32
emit 64   32x32@2x
emit 128  128x128
emit 256  128x128@2x
emit 256  256x256
emit 512  256x256@2x
emit 512  512x512
emit 1024 512x512@2x

iconutil -c icns "$ICONSET" -o "$1/Clio.icns"
echo "icon: Clio.icns"
