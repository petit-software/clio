cask "clio" do
  version "1.6"
  sha256 "e5eb26620e77eeca2443091d80c5eab5a5fdb9a0bd2ee3977555f48acd1a7e0d"

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
