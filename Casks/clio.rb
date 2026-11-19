cask "clio" do
  version "1.10"
  sha256 "29a93e3370792692a84869eaa45ae2bc87a63e1658c079fdfe967dd607d09986"

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
