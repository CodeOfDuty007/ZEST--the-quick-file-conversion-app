#!/bin/zsh
# Installs everything needed to build and test Zest on a clean Mac.
# Requires Xcode 26+ (App Store or developer.apple.com) and Homebrew.
set -euo pipefail

command -v xcodebuild >/dev/null || { echo "Install Xcode 26 or later first (the Liquid Glass APIs need the macOS 26 SDK)."; exit 1; }
command -v brew >/dev/null || { echo "Install Homebrew first: https://brew.sh"; exit 1; }

# xcodegen builds the Xcode project from project.yml. ffmpeg and webp are the optional
# engines for video/audio and WebP; Zest still runs without them and says what is missing.
brew list xcodegen >/dev/null 2>&1 || brew install xcodegen
brew list ffmpeg >/dev/null 2>&1 || brew install ffmpeg
brew list webp >/dev/null 2>&1 || brew install webp

echo "Ready. Next: make test, then make install"
