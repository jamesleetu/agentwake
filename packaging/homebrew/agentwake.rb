# Published copy of github.com/jamesleetu/homebrew-tap Formula/agentwake.rb.
# On a new release: bump url + sha256 (source tarball), then root_url + bottle sha256 from the Release job summary.
class Agentwake < Formula
  desc "Keep your Mac awake while Claude Code and long commands are running"
  homepage "https://github.com/jamesleetu/agentwake"
  url "https://github.com/jamesleetu/agentwake/archive/refs/tags/v0.1.2.tar.gz"
  sha256 "277e9b958329fd8bbe9aa76e77be385854b580605bb52a8b09be1875d66dbc7e"
  license "MIT"

  bottle do
    root_url "https://github.com/jamesleetu/agentwake/releases/download/v0.1.2"
    sha256 cellar: :any_skip_relocation, all: "9fe08fba0bbe4387cb2374e0df5633af5aed6021a66c83d720658d781e7c6823"
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
