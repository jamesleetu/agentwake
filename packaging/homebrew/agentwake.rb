# Copy to github.com/jamesleetu/homebrew-tap as Formula/agentwake.rb.
# Fill in sha256 after tagging: curl -sL <url> | shasum -a 256
class Agentwake < Formula
  desc "Keep your Mac awake while Claude Code and long commands are running"
  homepage "https://github.com/jamesleetu/agentwake"
  url "https://github.com/jamesleetu/agentwake/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "REPLACE_WITH_TARBALL_SHA256"
  license "MIT"

  depends_on xcode: ["15.0", :build]
  depends_on :macos

  def install
    system "swift", "build", "--disable-sandbox", "-c", "release"
    bin.install ".build/release/agentwake"
  end

  def caveats
    <<~EOS
      Connect agentwake to Claude Code:
        agentwake install-hooks
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/agentwake --version")
  end
end
