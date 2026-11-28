# 服务器准备

客户端连接时会自动检查服务器，缺什么提示一键安装。下面是在终端里手动准备服务器、配置执行账号和多人共用的方法。

## 一键准备

在本地仓库目录运行，脚本先通过 SSH 连接远端，再检测和安装 Claude：

```sh
sh scripts/setup-remote.sh my-server
# 或指定端口、私钥和用户
sh scripts/setup-remote.sh -p 2222 -i ~/.ssh/id_ed25519 user@example.com
```

- 使用系统 OpenSSH，支持 SSH config 别名、密码和密钥；保留主机指纹检查。
- **已有 Claude：** 只验证能否运行，不覆盖、不升级、不改认证配置。
- **没有 Claude：** 下载 [Claude 官方安装器](https://github.com/anthropics/claude-code#installation)并安装 stable 版本，由官方安装器选择平台和架构。
- 远端 Node.js 低于 18.14 或不存在时，把固定版本、校验过 SHA-256 的 Node.js 装到用户目录，不改系统包（nodejs.org 不通时换 npmmirror；Alpine、CentOS 7 用非官方构建）。唯一例外：Alpine 上以 root 连接时会 `apk add libstdc++`，Node.js 的 musl 构建依赖它。
- 以 root 登录 Linux 时，若 TCP 仍是默认的 cubic / reno，自动切到 BBR，写入 `/etc/sysctl.d/90-tether-net.conf`（只改仍为默认值的项）。高延迟、有丢包的跨境线路上，文件传输可快数倍；删除该文件即可还原。
- SSH 断开会杀后台进程的服务器上自动开启 `loginctl enable-linger`；需要管理员权限时先试免密 `sudo`，不行再给出要运行的命令。
- 不会自动登录、索取 API Key，也不会把本机 Claude 凭据传到服务器。

如需登录，请在服务器交互式终端运行 `claude auth login`；新安装通常位于 `~/.local/bin/claude`。完成后回到客户端连接同一主机。安装器要求远端能访问官方站点；发行地区、网络或系统依赖问题会按实际错误显示。

**该步骤由你运行脚本触发，不是每次客户端连接都静默安装。** DMG 内也附带这两个脚本；一起复制到本地后即可使用。

**想让 Claude 以普通账号运行**（root 登录也可以直接用 Full Access，见[使用说明](usage.md#full-access-与-root)）再加三个选项，一条命令配好执行账号：

```sh
sh scripts/setup-remote.sh --runner claude-runner --project /opt/projects/my-app root@example.com
```

| 选项 | 作用 |
| --- | --- |
| `--runner 账号` | 新建普通账号并为它安装 Claude Code。同名账号已存在且不是本脚本创建的，直接拒绝，不修改已有账号 |
| `--project 目录` | 目录不存在则创建；只给该账号这个目录的读写权限（ACL），父目录仅可穿越。缺少 `setfacl` 时用系统包管理器安装 `acl`。拒绝 `/root`、`/etc` 等系统目录 |
| `--copy-login` | 把 root 的 `~/.claude/.credentials.json` 复制给该账号（仅此一个文件，权限 600）。不加则按脚本最后打印的命令登录一次 |

选项在安装任何东西之前检查，重复运行不会重复创建。完成后在新对话选择 Full Access，执行账号填 `claude-runner`。

## 多人共用一台服务器

每人一个 Linux 账号、自己的 SSH 密钥和 Claude 登录；家目录为 `700`，对话、文件、附件、任务和用量互相看不到。以 root 连接时，服务器旁出现「成员」，可添加（账号 + 公钥）和删除。也可以在终端运行：

```bash
sudo bash scripts/install-claude-remote.sh --add-user alice --key 'ssh-ed25519 AAAA… alice@laptop'
sudo bash scripts/install-claude-remote.sh --list-users
sudo bash scripts/install-claude-remote.sh --remove-user alice   # 删除账号和家目录
```

只管理本脚本创建的账号（记录在 `/etc/claude-mirror/members`），已有账号不会被修改或删除。成员用 `alice@服务器` 添加服务器，首次连接后自己登录 Claude。

## 连接码与网页面板

不想让成员自己生成密钥、填地址时，用连接码：

```bash
sudo bash scripts/install-claude-remote.sh --invite alice   # 打印 cm1. 开头的连接码
```

连接码里有服务器地址、SSH 端口、账号、服务器指纹和一把邀请密钥。成员在 App 添加服务器时粘贴即可连上，不用确认指纹。

- 24 小时内有效（需要 OpenSSH 8.2+），只能用一次。
- 首次连接时 App 生成本机密钥并换掉邀请密钥，邀请密钥随即作废。
- 再次 `--invite` 会作废旧的连接码。

也可以装一个网页面板，在浏览器里添加、删除成员和复制连接码（需要 systemd）：

```bash
curl -fsSL https://github.com/xirichuyi/tether/releases/latest/download/install-claude-remote.sh | sudo bash -s -- --panel
```

- 端口、网页路径、账号和密码随机生成，只在首次安装时显示；`--panel-reset` 重新生成账号和密码，`--remove-panel` 卸载（成员保留）。
- 只走 HTTPS，用服务器自签证书；浏览器首次会提示不受信任，可对照安装时打印的证书指纹确认。
- 安装时会在 ufw / firewalld 放行端口；云服务商的安全组需要自己放行。
- 登录连续失败 5 次锁定 10 分钟。
