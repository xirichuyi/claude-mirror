#!/bin/sh
# Reproducible drag-to-Applications disk image for the current Mac architecture.
set -eu
cd "$(dirname "$0")/.."
BUILD_CONFIGURATION=release sh scripts/build-app.sh
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)
ARCH=$(uname -m)
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/claude-mirror-dmg.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
APP="$STAGE/claude-mirror.app"
ditto --noextattr dist/claude-mirror.app "$APP"
xattr -dr com.apple.FinderInfo "$APP" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$APP" 2>/dev/null || true
codesign --verify --deep --strict "$APP"
ln -s /Applications "$STAGE/Applications"
cp ../scripts/setup-remote.sh ../scripts/install-claude-remote.sh "$STAGE/"
cat > "$STAGE/安装说明.txt" <<'TEXT'
claude-mirror 安装说明

1. 把 claude-mirror.app 拖到旁边的 Applications（应用程序）文件夹。
2. 从“应用程序”打开 claude-mirror。

第一次打开时，macOS 可能提示“无法验证开发者”或“Apple 无法检查其是否包含恶意软件”。
这是因为此版本还没有经过 Apple 公证，不代表文件损坏。确认是从
https://github.com/xirichuyi/claude-mirror/releases 下载的之后：
  a. 在提示框里点“完成”（不要点“移到废纸篓”）；
  b. 打开“系统设置 > 隐私与安全性”，滚动到底部“安全性”；
  c. 找到“已阻止 claude-mirror”，点“仍要打开”，输入登录密码确认；
  d. 再次打开 claude-mirror，在弹窗中点“打开”。
之后就能正常打开，应用内更新也不会再出现这个提示。请勿关闭全局 Gatekeeper。

要求 macOS 14 或更新版本。服务器端只需要能用 SSH 登录：缺少的 Claude Code 和
Node.js 可以在应用里一键安装（装在你的用户目录，不需要管理员权限）。
也可以在终端执行 sh setup-remote.sh 服务器地址（两个脚本需放在同一目录）。

入门指南：https://github.com/xirichuyi/claude-mirror/blob/HEAD/docs/getting-started.md
TEXT
OUTPUT="dist/claude-mirror-${VERSION}-macOS-${ARCH}.dmg"
# hdiutil occasionally reports "Resource busy" on CI machines; retry before failing.
for attempt in 1 2 3; do
  hdiutil create -volname 'claude-mirror' -srcfolder "$STAGE" -format UDZO -ov "$OUTPUT" && break
  [ "$attempt" = 3 ] && exit 1
  sleep 5
done
hdiutil verify "$OUTPUT"
(cd dist && shasum -a 256 "$(basename "$OUTPUT")" > "$(basename "$OUTPUT").sha256")
echo "$OUTPUT"
