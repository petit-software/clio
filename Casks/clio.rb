cask "clio" do
  version "1.8"
  sha256 "7f43b304a3a396f942c53fd50e3278a0fd96f0c41f6813fb32a126f5e8a027ea"

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
