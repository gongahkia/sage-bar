class ClaudeUsageCli < Formula
  desc "CLI tool for tracking Claude API token and cost usage"
  homepage "https://github.com/gongahkia/sage-bar"
  version "1.0.0"
  sha256 "PLACEHOLDER_SHA256" # updated on each release by CI

  on_macos do
    if Hardware::CPU.arm?
      url "https://github.com/gongahkia/sage-bar/releases/download/v#{version}/claude-usage-arm64"
      sha256 "PLACEHOLDER_ARM64_SHA256"
    else
      url "https://github.com/gongahkia/sage-bar/releases/download/v#{version}/claude-usage-x86_64"
      sha256 "PLACEHOLDER_X86_SHA256"
    end
  end

  def install
    bin.install Dir["claude-usage*"].first => "claude-usage"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/claude-usage --version")
  end
end
