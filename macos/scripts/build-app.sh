#!/bin/sh
# Builds macos/dist/claude-mirror.app. Needs Xcode command line tools, Node.js, and `npm ci` at the repo root.
set -eu
cd "$(dirname "$0")/.."
node scripts/prepare-server.cjs Resources/server
swift build -c "${BUILD_CONFIGURATION:-release}" --product RemoteCC
STAGING=$(mktemp -d "${TMPDIR:-/tmp}/remotecc-build.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT HUP INT TERM
APP="$STAGING/claude-mirror.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$(swift build -c "${BUILD_CONFIGURATION:-release}" --show-bin-path)/RemoteCC" "$APP/Contents/MacOS/RemoteCC"
mkdir -p "$APP/Contents/Frameworks"
ditto .build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework "$APP/Contents/Frameworks/Sparkle.framework"
swiftc Helpers/ClaudockAskpass.swift -o "$APP/Contents/MacOS/ClaudockAskpass"
codesign --force --sign - "$APP/Contents/MacOS/ClaudockAskpass"
cp -R Resources/server "$APP/Contents/Resources/server"
cp -R Resources/ThirdParty "$APP/Contents/Resources/ThirdParty"
cp Resources/BrandIcon.png "$APP/Contents/Resources/BrandIcon.png"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Sign outside synced workspaces, whose file provider can reintroduce FinderInfo.
xattr -dr com.apple.FinderInfo "$APP" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$APP" 2>/dev/null || true
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict "$APP"
mkdir -p dist
rm -rf dist/claude-mirror.app
ditto --noextattr "$APP" dist/claude-mirror.app
# A synced destination may attach Finder metadata shortly after the copy.
# Only remove the two attributes prohibited by codesign; never bypass verification.
for attempt in 1 2 3; do
  xattr -dr com.apple.FinderInfo dist/claude-mirror.app 2>/dev/null || true
  xattr -dr com.apple.ResourceFork dist/claude-mirror.app 2>/dev/null || true
  if codesign --verify --deep --strict dist/claude-mirror.app; then
    echo "Built dist/claude-mirror.app"
    exit 0
  fi
  sleep 1
done
codesign --verify --deep --strict dist/claude-mirror.app
echo "Built dist/claude-mirror.app"
