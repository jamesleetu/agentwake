# Published copy of github.com/jamesleetu/homebrew-tap Formula/agentwake.rb.
# On a new release: bump url + sha256 (source tarball), then root_url + bottle sha256 from the Release job summary.
class Agentwake < Formula
  desc "Keep your Mac awake while Claude Code and long commands are running"
  homepage "https://github.com/jamesleetu/agentwake"
  url "https://github.com/jamesleetu/agentwake/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "e388548ac6ad7391fe8ee83fb34081087b622b0a631ce7672306855fe3334920"
  license "MIT"

  bottle do
    root_url "https://github.com/jamesleetu/agentwake/releases/download/v0.1.0"
    sha256 cellar: :any_skip_relocation, all: "f027040640d0fbb900b2ebd848daa3037878958ecdf9987d58d2970a235a2e61"
  end

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
