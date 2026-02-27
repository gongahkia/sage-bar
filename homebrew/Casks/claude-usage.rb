cask "claude-usage" do
  version "1.0.0"
  sha256 "PLACEHOLDER_SHA256" # updated on each release by CI

  url "https://github.com/gongahkia/claude-usage-tracker/releases/download/v#{version}/ClaudeUsage-v#{version}.dmg"
  name "Claude Usage"
  desc "macOS menu bar app tracking Claude token and cost usage"
  homepage "https://github.com/gongahkia/claude-usage-tracker"

  app "ClaudeUsage.app"

  zap trash: [
    "~/.claude-usage",
    "~/Library/Application Support/ClaudeUsage",
    "~/Library/Preferences/dev.claudeusage.ClaudeUsage.plist",
  ]
end
