# Homebrew cask for Offprint.
#
# This file is the source of truth; it is published by copying it into the tap
# repository `J0nasW/homebrew-offprint` as `Casks/offprint.rb`. A tap must live
# in a repo whose name begins with `homebrew-`, so it cannot be served from this
# one.
#
#   brew install --cask J0nasW/offprint/offprint
#
# Note: `--no-quarantine` no longer exists — Homebrew deprecated it in October
# 2025 and removed the last of it in July 2026 — so a cask install is quarantined
# exactly like a direct download. Until Offprint is notarised, first launch needs
# System Settings -> Privacy & Security -> Open Anyway. The cask is for
# convenient installs and upgrades, not for bypassing Gatekeeper.
cask "offprint" do
  version "0.1.0"
  sha256 :no_check   # the download URL is a moving "latest" pointer

  url "https://github.com/J0nasW/offprint/releases/latest/download/Offprint.dmg"
  name "Offprint"
  desc "Convert PDFs to Markdown and JSON entirely on-device"
  homepage "https://github.com/J0nasW/offprint"

  depends_on macos: ">= :tahoe"
  depends_on arch: :arm64

  app "Offprint PDF to Markdown.app"

  zap trash: [
    "~/Library/Application Support/de.boostnow.Offprint",
    "~/Library/Preferences/de.boostnow.Offprint.plist",
    "~/Library/Saved Application State/de.boostnow.Offprint.savedState",
  ]
end
