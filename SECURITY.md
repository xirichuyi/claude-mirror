# 安全说明

发现安全问题请不要公开提交 Issue，用 GitHub 的 [Private vulnerability reporting](https://github.com/xirichuyi/tether/security/advisories/new) 私下报告。

## 数据与安全边界

聊天和缓存保存在本机；兼容路径为 `~/Library/Application Support/RemoteCC Native`，机器配置保存在应用 UserDefaults。机器配置包含地址、名称、认证方式与私钥路径，不包含密码和私钥内容。

聊天附件上传到远端专用临时目录，按 SHA-256 摘要隔离；重复附件验证远端副本后复用路径，副本丢失或内容变化时重新上传。文件面板的上传仍写入当前浏览目录。临时目录可能被系统清理，不用作长期文件存储；发起聊天会将请求及所附内容交给远端 Claude。权限请求仍需按配置确认，断线不会自动批准。编辑远端文件可能改变服务器项目，检查点回退只覆盖 SDK 跟踪的文件，不等于整个项目快照。

请勿向仓库提交认证文件、私钥、聊天数据库或生产环境配置。
