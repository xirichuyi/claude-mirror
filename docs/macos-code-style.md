# macOS 界面代码规范

## 目录与职责

`macos/Sources/RemoteCC` 中，本轮整理的代码按职责归档：

- `DesignSystem/`：主题、尺寸、图标、按钮、表单、菜单、弹窗、动画。不得依赖 `AppModel`、SSH 或业务状态。
- `Features/Hosts/`：主机选择、连接、管理、环境安装、密钥登录。
- `Features/Settings/`：设置导航与设置页面。
- `Workspace/`：侧栏导航、同步入口、底栏。
- `Persistence/`：偏好设置的读取、保存及恢复策略。通过注入 `UserDefaults` 使用隔离测试数据。
- `RemoteCCCore`：协议、传输、会话与文件操作，不引入 SwiftUI。

其余已有功能文件暂保留原位。修改功能时按职责归档，不为移动而移动。不要创建新的 `Utils`、`CommonViews` 或无关类型混杂的大文件。

## 组件

先复用 `WorkbenchIconButtonStyle`、`QuietButtonStyle`、`WorkbenchButtonStyle`、`WorkbenchFormRow`、`WorkbenchSelect`、`WorkbenchMenu` 和 `SheetHeading`。只有重复的行为或视觉规则才抽成公共组件，业务专用组件留在功能目录。

颜色来自 `WorkbenchTheme`，公共尺寸来自 `WorkbenchMetrics`。不要在页面重复实现悬停、选中、禁用或输入框边框。新增公共组件默认内部可见，辅助类型和状态保持 `private`。

设置分区、状态和选项用枚举或稳定 ID，不用显示文案作为业务判断。列表使用稳定身份。跨界面生命周期需要恢复的状态放到持久化层，临时交互状态放到最小的视图。

## 动画与性能

动画时长和过渡统一在 `DesignSystem/Motion.swift`。页面通过 `accessibilityReduceMotion` 传入策略；减少动态效果时不做位移、缩放或滚动动画。

动画只绑定明确的用户交互或局部状态。禁止给整个聊天列表、流式文本、滚动位置或网络轮询结果添加隐式动画。不要为了统一动画，额外让所有悬停或切换都动起来。

AppKit 桥接只用于原生滚动、文本或无原生菜单外观的弹窗等必要能力。事件监听必须配对清理；延迟展示必须能取消；不可吞掉无关窗口的输入。

## 清理与验证

删除未使用的类型、分支和常量。注释说明约束、来源或原因，不复述代码。不要保留备用实现或一层套一层、没有职责的视图。

格式：4 空格，120 列；使用 `macos/.swift-format`。`macos/scripts/check-ui-style.sh` 检查已整理目录。已有未整理文件在实际修改时逐步接入，不混入全仓格式变更。

行为变化补边界测试；纯样式调整编译并检查界面。主机相关测试必须用隔离偏好设置和临时目录，不删除真实主机，不发送真实聊天。发布前运行 `swift test --package-path macos`，集成测试需要根目录 Node 依赖已安装。
