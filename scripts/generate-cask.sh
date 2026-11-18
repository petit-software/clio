#!/bin/bash
# Writes the Homebrew cask for a release: packaging/homebrew/clio.rb, from
# the notarized DMG in dist/ — the same file that was uploaded to GitHub.
#
#   scripts/generate-cask.sh            # the version in Resources/Info.plist
#   scripts/generate-cask.sh 1.6
#
# After release.sh and the GitHub release, like the appcast: a cask that
# names a download that does not exist yet fails for everyone who installs.
# The file it writes is then copied into the tap (see packaging/homebrew/README.md).
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)}"
DMG="dist/Clio-${VERSION}.dmg"
[ -f "$DMG" ] || { echo "No $DMG — run scripts/release.sh first." >&2; exit 1; }
SHA="$(shasum -a 256 "$DMG" | cut -d' ' -f1)"

mkdir -p packaging/homebrew
cat > packaging/homebrew/clio.rb <<CASK
cask "clio" do
  version "${VERSION}"
  sha256 "${SHA}"

  url "https://github.com/petit-software/clio/releases/download/v#{version}/Clio-#{version}.dmg"
  name "Clio"
  desc "Dictation and meeting notes, transcribed entirely on this Mac"
  homepage "https://github.com/petit-software/clio"

  livecheck do
    url :url
    strategy :github_latest
  end

  # Clio updates itself with Sparkle.
  auto_updates true
  depends_on macos: ">= :sonoma"
  depends_on arch: :arm64

  app "Clio.app"

  zap trash: [
    "~/Library/Application Support/com.bartbak.clio",
    "~/Library/Caches/com.bartbak.clio",
    "~/Library/HTTPStorages/com.bartbak.clio",
    "~/Library/Preferences/com.bartbak.clio.plist",
  ]

  caveats <<~EOS
    Meeting notes are kept in ~/Documents/Clio Meetings and are not removed
    with the app, or by --zap.
  EOS
end
CASK
echo "Wrote packaging/homebrew/clio.rb for ${VERSION} (${SHA})"
