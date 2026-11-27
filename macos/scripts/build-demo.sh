#!/bin/sh
# Debug build with the demo bundle ID: fictional data, no real connections. For screenshots only.
set -eu
cd "$(dirname "$0")/.."
BUILD_CONFIGURATION=debug sh scripts/build-app.sh >/dev/null
rm -rf dist/TetherDemo.app
ditto --noextattr dist/Tether.app dist/TetherDemo.app
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.claudemirror.demo' dist/TetherDemo.app/Contents/Info.plist
codesign --force --deep --sign - dist/TetherDemo.app
echo "Built dist/TetherDemo.app"
