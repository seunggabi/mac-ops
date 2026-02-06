class MacOps < Formula
  desc "macOS system optimization CLI tool"
  homepage "https://github.com/seunggabi/mac-ops"
  url "https://github.com/seunggabi/mac-ops/archive/refs/tags/v1.0.0.tar.gz"
  # sha256 will be filled after release
  license "MIT"

  depends_on :macos

  def install
    # Install all files preserving directory structure
    prefix.install "bin", "lib", "config", "launchd"

    # Create symlink for the main executable
    bin.install_symlink prefix/"bin/mac-ops"
  end

  def caveats
    <<~EOS
      To enable scheduled cleanup, run:
        mac-ops install

      Full Disk Access is required for some cleanup operations.
      Go to System Settings > Privacy & Security > Full Disk Access
      and add your terminal application.
    EOS
  end

  test do
    assert_match "mac-ops v", shell_output("#{bin}/mac-ops version")
  end
end
