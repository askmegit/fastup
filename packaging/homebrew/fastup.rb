# Template for the tap repo askmegit/homebrew-tap (Formula/fastup.rb).
class Fastup < Formula
  desc "Probe download sources and update AI coding CLIs from the fastest, checksum-verified one"
  homepage "https://github.com/askmegit/fastup"
  version "0.1.0"
  # sha256 is filled at release time from the release asset digest.
  url "https://github.com/askmegit/fastup/releases/download/v#{version}/fastup"
  sha256 "REPLACE_WITH_RELEASE_SHA256"
  license "MIT"

  depends_on :macos

  def install
    bin.install "fastup"
  end

  test do
    system "#{bin}/fastup", "--help"
  end
end
