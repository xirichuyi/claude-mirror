#!/bin/sh
# Reproducible drag-to-Applications disk image for the current Mac architecture.
set -eu
cd "$(dirname "$0")/.."
BUILD_CONFIGURATION=release sh scripts/build-app.sh
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
ARCH=$(uname -m)
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/claude-mirror-dmg.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/Claude Mirror.app"
ditto --noextattr dist/RemoteCC.app "$APP"
xattr -dr com.apple.FinderInfo "$APP" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$APP" 2>/dev/null || true
codesign --verify --deep --strict "$APP"
ln -s /Applications "$STAGE/Applications"
cp ../scripts/setup-remote.sh ../scripts/install-claude-remote.sh "$STAGE/"
cat > "$STAGE/安装说明.txt" <<'TEXT'
镜像 Claude / Claude Mirror
将 Claude Mirror.app 拖入 Applications，然后从应用程序打开。
要求 macOS 14 或更新版本。远端需要 SSH、Node.js >=18.14、Claude Code。
远端安装：在终端执行 sh setup-remote.sh 你的SSH别名（两个脚本需保存在同一目录）。
此版本为 ad-hoc 签名，尚未经过 Apple 公证。系统可能阻止首次启动；核对来源后，在“系统设置 > 隐私与安全性”中允许本次打开。请勿关闭全局 Gatekeeper。
项目与帮助：https://github.com/xirichuyi/claude-mirror
TEXT
OUTPUT="dist/Claude-Mirror-${VERSION}-macOS-${ARCH}.dmg"
# hdiutil occasionally reports "Resource busy" on CI machines; retry before failing.
for attempt in 1 2 3; do
  hdiutil create -volname 'Claude Mirror' -srcfolder "$STAGE" -format UDZO -ov "$OUTPUT" && break
  [ "$attempt" = 3 ] && exit 1
  sleep 5
done
hdiutil verify "$OUTPUT"
(cd dist && shasum -a 256 "$(basename "$OUTPUT")" > "$(basename "$OUTPUT").sha256")
echo "$OUTPUT"
