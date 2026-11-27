# 发布流程

## CI 与发布工作流

- **CI**（`.github/workflows/ci.yml`）：推送到 main 或提交 PR 时，在 Linux 上运行 Node 测试，在 macOS 26（Apple Silicon，Xcode 26）上运行 Swift 测试并打包 DMG。DMG 作为构建产物保留 14 天，可在对应运行记录中下载。
- **Release**（`.github/workflows/release.yml`）：推送 `v*` 标签时，先核对标签与 `Info.plist` 中的版本号一致，再测试、打包，并把 DMG、校验文件和远端脚本上传到同名 Release。Release 不存在时自动创建，说明取自 `docs/releases/<标签>.md`。也可以在 Actions 页面手动运行，为已有标签重新构建并上传。

发布新版本：

```sh
# 1. 修改 macos/Resources/Info.plist 中的 CFBundleShortVersionString 和 CFBundleVersion
# 2. 编写 docs/releases/v0.20.0.md
git commit -am "Release v0.20.0" && git push origin main
git tag -a v0.20.0 -m "claude-mirror v0.20.0" && git push origin v0.20.0
```

CI 构建同样只做 ad-hoc 签名，不经过 Apple 公证。

## 发布一个稳定版本

1. 在 `macos/Resources/Info.plist` 更新产品版本（两端共用），并递增 Sparkle build number。在 `docs/releases/vX.Y.Z.md` 写一份更新说明，分别标注 Windows 和 macOS 的变化。只有单平台改动时也使用统一补丁版本。
2. 维护者可先在 GitHub Actions 手动运行 **Stable release**，保留默认的 rehearsal 选项。在指定源码上执行两端构建、签名和校验，产物仅出现在 Actions，不会创建 Release 或变更更新源。
3. 从已验证的提交创建并推送 `vX.Y.Z` 标签。工作流从同一提交分别构建 Windows 和 macOS；两端通过后，将 EXE、DMG、便携 ZIP、摘要和更新元数据上传到同一个草稿，逐项核验 GitHub 摘要，然后公开并设为 Latest。Sparkle 的稳定更新源在发布成功后更新。
4. 失败时修复原因并重试。已公开的附件不允许替换；若只是发布更新源失败，重试沿用已公开的原始字节。带平台后缀的历史标签不参与稳定发布。

Windows 新客户端启动时在后台检查同一稳定版本，也可从“更多操作 → 检查更新”手动检查。下载完成后选择“重启更新”。Windows 首发版用户须手动安装首个包含更新器的统一版本一次。

## 维护 macOS 自动更新

发布工作流通过 `SPARKLE_PRIVATE_KEY` GitHub Actions Secret 签名 DMG 和 appcast，在 Release 资产上传成功后更新 `updates` 分支的 `appcast.xml`。客户端内置公钥，安装前验证更新包和更新源。每次发布必须同时递增 `CFBundleShortVersionString` 和 `CFBundleVersion`；Windows 预览标签不会进入 macOS 更新源。

本地签名工具随 SwiftPM 的 Sparkle 依赖下载，私钥保存在 macOS 登录钥匙串的 `claude-mirror` account 中，不应提交到仓库。请备份签名私钥；丢失后无法给现有安装继续签署可信更新。手动生成更新源：`bash macos/scripts/generate-appcast.sh`。更新源必须在对应安装包可下载后发布，签名后的 XML 不能手工修改。
