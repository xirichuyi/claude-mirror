#!/bin/bash
# Generate a signed feed for the exact release artifact. No private keys in arguments/logs.
set -euo pipefail
cd "$(dirname "$0")/../.."
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' macos/Resources/Info.plist)
archive="claude-mirror-${version}-macOS-arm64.dmg"
feed_dir=$(mktemp -d)
trap 'rm -r "$feed_dir"' EXIT
cp "macos/dist/$archive" "$feed_dir/"
cp "docs/releases/v${version}.md" "$feed_dir/${archive%.dmg}.md"
args=(--download-url-prefix "https://github.com/xirichuyi/claude-mirror/releases/download/v${version}/" --embed-release-notes --maximum-deltas 0)
tool=macos/.build/artifacts/sparkle/Sparkle/bin/generate_appcast
if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
  printf '%s' "$SPARKLE_PRIVATE_KEY" | "$tool" --ed-key-file - "${args[@]}" "$feed_dir"
else
  "$tool" --account claude-mirror "${args[@]}" "$feed_dir"
fi
cp "$feed_dir/appcast.xml" macos/dist/appcast.xml
