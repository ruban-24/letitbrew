cask "letitbrew" do
  version "1.0.1"
  sha256 "783290321a17e5d74bc29dece3504f04779d3a94b1d63aa9e3d651303df98d25"

  url "https://github.com/ruban-24/letitbrew/releases/download/v#{version}/LetItBrew-#{version}.dmg"
  name "Let It Brew"
  desc "Menu-bar app that prevents sleep while coding agents work"
  homepage "https://github.com/ruban-24/letitbrew"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: :sonoma

  app "Let It Brew.app"
  binary "#{appdir}/Let It Brew.app/Contents/Helpers/letitbrew"

  # Quit first so the app releases its holds. Then, while the app bundle
  # still exists, reconcile the sleep setting and unregister the privileged
  # helper, like the in-app uninstaller. Skips quietly when the app is gone,
  # the helper was never registered, or reconciliation fails.
  uninstall quit:   "com.ruban24.letitbrew",
            script: {
              executable:   "/bin/sh",
              args:         [
                "-c",
                '[ -x "$1" ] || exit 0; s=$("$1" --prepare-update) || exit 0; ' \
                'case $s in *registered*) "$1" --unregister-daemon ;; esac',
                "sh",
                "#{appdir}/Let It Brew.app/Contents/MacOS/LetItBrew",
              ],
              must_succeed: false,
            }

  zap trash: [
    "~/Library/Application Support/LetItBrew",
    "~/Library/Preferences/com.ruban24.letitbrew.plist",
  ]

  caveats <<~EOS
    Let It Brew must run from /Applications/Let It Brew.app.
    To remove its agent hooks, use Settings → About → Uninstall Let It Brew….
  EOS
end
