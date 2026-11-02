#!/bin/sh
# Debug build with the demo bundle ID: fictional data, no real connections. For screenshots only.
set -eu
cd "$(dirname "$0")/.."
BUILD_CONFIGURATION=debug sh scripts/build-app.sh >/dev/null
rm -rf dist/ClaudeMirrorDemo.app
ditto --noextattr dist/claude-mirror.app dist/ClaudeMirrorDemo.app
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.claudemirror.demo' dist/ClaudeMirrorDemo.app/Contents/Info.plist
codesign --force --deep --sign - dist/ClaudeMirrorDemo.app
echo "Built dist/ClaudeMirrorDemo.app"
