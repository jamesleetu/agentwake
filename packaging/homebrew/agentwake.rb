# Published copy of github.com/jamesleetu/homebrew-tap Formula/agentwake.rb.
# On a new release: bump url + sha256 (source tarball), then root_url + bottle sha256 from the Release job summary.
class Agentwake < Formula
  desc "Keep your Mac awake while Claude Code and long commands are running"
  homepage "https://github.com/jamesleetu/agentwake"
  url "https://github.com/jamesleetu/agentwake/archive/refs/tags/v0.1.1.tar.gz"
  sha256 "19e963db42c59c6a0f51a4658cc1738539f94c3584d676b554290c5344113e91"
  license "MIT"

  bottle do
    root_url "https://github.com/jamesleetu/agentwake/releases/download/v0.1.1"
    sha256 cellar: :any_skip_relocation, all: "56a324cfdc1d3693a7d907994124fd8f1cada3e57af540aec73ea85fbd42e248"
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
