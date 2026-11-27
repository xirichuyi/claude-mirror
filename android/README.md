# Tether · Android

Kotlin + Jetpack Compose 客户端，用 [sshj](https://github.com/hierynomus/sshj) 直接连接服务器，和 macOS、Windows 走同一套远端代理协议，不经过中转服务。

## 功能

- 多服务器，用密码、私钥文件或连接码登录；密码和私钥用 Android Keystore 加密保存在本机。
- 第一次连接核对服务器指纹，之后指纹变了拒绝连接。
- 多项目和目录选择，接着服务器上已有的对话，重命名。
- 流式回复、工具卡片、权限确认、Claude 的提问；切换模型和思考强度。
- 排队、插队、停止；输入框上方显示上下文用量。
- 照片和文件附件，走已有连接，断点续传。
- 远端文件浏览，预览文本和图片；Git 改动和单文件差异。
- 内置终端，在当前项目目录打开登录 shell。
- 后台保持连接，回复完成或需要确认时发通知。
- root 登录时管理成员。

## 构建

需要 JDK 17、Android SDK（`compileSdk 37`）和 Node.js。构建时会用仓库里的 TypeScript 源码生成随 App 携带的服务端程序。

```sh
cd android
./gradlew assembleDebug   # app/build/outputs/apk/debug/app-debug.apk
./gradlew test            # 引擎与协议测试，会在本机运行真实的远端代理
./gradlew lint
```

## 结构

- `core/`：SSH、远端代理协议、会话和传输，纯 Kotlin，可在 JVM 上测试。
- `app/`：Compose 界面、后台服务、通知和本地存储。

## 真实服务器测试

`SshEndToEndTest` 默认跳过。设置 `CLAUDE_MIRROR_E2E_HOST` 等环境变量后，会通过真实 SSH 对一台准备好的服务器跑完整对话，说明见该文件开头。

## 发布签名

CI 产出的是调试签名 APK。正式签名需要维护者的 keystore，不要提交到仓库。
