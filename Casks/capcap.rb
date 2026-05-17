cask "capcap" do
  version "1.1.7"
  sha256 "ad150bd1f0b550c829f5f60cd05c3390e82537982204742c685c7cbdeeb378fe"

  url "https://github.com/realskyrin/capcap/releases/download/release-v#{version}/capcap-#{version}-macos.zip"
  name "capcap"
  desc "Lightweight native macOS menu bar screenshot tool"
  homepage "https://github.com/realskyrin/capcap"

  depends_on macos: ">= :sonoma"

  app "capcap.app"

  uninstall quit: "cn.skyrin.capcap"

  zap trash: [
    "~/Library/Preferences/cn.skyrin.capcap.plist",
  ]
end
