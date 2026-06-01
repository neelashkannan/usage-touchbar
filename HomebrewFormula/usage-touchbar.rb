class UsageTouchbar < Formula
  desc "Real-time Claude Code, Codex, and OpenCode usage limits on the macOS Touch Bar and CLI"
  homepage "https://github.com/neelashkannan/usage-touchbar"
  url "https://github.com/neelashkannan/usage-touchbar/archive/refs/tags/v1.0.0.tar.gz"
  sha256 "REPLACE_WITH_SHA256_OF_RELEASE_TARBALL"
  license "MIT"

  # Built against the macOS 13 SDK; older releases will not have the Swift
  # Concurrency / NSTouchBar APIs this project depends on.
  depends_on :macos => :ventura
  depends_on xcode: ["16.0", :build]

  # Universal build is required because the bundled `scripts/build-and-sign.sh`
  # produces an arm64 + x86_64 fat Mach-O so the same binary runs on both
  # Apple Silicon and Intel Touch Bar MacBook Pros.
  def install
    # `swift build` produces a release-style binary at:
    #   .build/apple/Products/Release/usage-touchbar (when --arch flags are set)
    #   .build/release/usage-touchbar                         (otherwise)
    # We use the same universal invocation the project documents in
    # README.md so the Homebrew-built binary is bit-for-bit identical to a
    # `git clone` + `./scripts/build-and-sign.sh` build.
    system "swift", "build",
           "-c", "release",
           "--arch", "arm64",
           "--arch", "x86_64",
           "--product", "usage-touchbar"

    # `.build/apple/Products/Release` is the SwiftPM path when
    # `--arch arm64 --arch x86_64` is supplied; fall back to
    # `.build/release` for any future change to the build script.
    release_bin = Pathname(".build/apple/Products/Release/usage-touchbar")
    release_bin = Pathname(".build/release/usage-touchbar") unless release_bin.exist?
    raise "Could not locate the built binary" unless release_bin.exist?
    bin.install release_bin => "usage-touchbar"

    # Install the README so `brew info usage-touchbar` shows the
    # usage / install instructions.
    prefix.install "README.md" => "README.md" if File.exist?("README.md")
  end

  test do
    # `usage-touchbar help` exits 0 and prints the usage text. We pipe
    # through `head -1` so the test does not depend on the entire help
    # block being byte-for-byte stable.
    assert_match "usage-touchbar", shell_output("#{bin}/usage-touchbar help", 0)
    assert_match "Claude, Codex & OpenCode", shell_output("#{bin}/usage-touchbar help", 0)
  end
end
