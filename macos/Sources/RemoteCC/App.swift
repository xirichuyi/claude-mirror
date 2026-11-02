#if canImport(SwiftUI)
import SwiftUI
import Network
import AppKit
import UserNotifications
import RemoteCCCore

@main
struct RemoteCCApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("镜像 Claude") {
            RootView()
                .environmentObject(model)
                .frame(minWidth: 1000, minHeight: 620)
                .onAppear { delegate.model = model; model.startUpdateChecks() }
        }
        .defaultSize(width: 1160, height: 760)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("检查更新…") { Task { await model.checkForUpdates(manual: true) } }
            }
            CommandGroup(replacing: .newItem) {
                Button("新对话") { model.newConversation() }.keyboardShortcut("n")
                Button("快速打开文件…") { model.showQuickOpen = true }.keyboardShortcut("p")
                Button("关闭文件标签") { model.closeActiveTab() }.keyboardShortcut("w")
            }
            CommandGroup(after: .saveItem) {
                Button("保存到远端") { model.saveActiveTab() }.keyboardShortcut("s")
            }
            CommandMenu("工作区") {
                Button("在文件中搜索") { model.panel = .search; model.showFiles = true }.keyboardShortcut("f", modifiers: [.command, .shift])
                Button("显示 / 隐藏文件面板") { model.showFiles.toggle() }.keyboardShortcut("b")
                Divider()
                Button("模型与会话设置…") { model.showPreferences = true }
                Button("连接 SSH…") { model.showConnect = true }
                #if DEBUG
                Divider()
                Button("聊天交互预览…") { model.showChatGallery = true }
                #endif
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    weak var model: AppModel?
    private let networkMonitor = NWPathMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A bare SwiftPM executable starts as a background process unless told otherwise.
        UNUserNotificationCenter.current().delegate = self
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        #if DEBUG
        captureSnapshotIfRequested()
        #endif
        networkMonitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in await self?.model?.connections?.networkBecameAvailable() }
        }
        networkMonitor.start(queue: DispatchQueue(label: "remotecc.network-path"))
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.model?.connections?.networkBecameAvailable() }
        }
    }

    #if DEBUG
    /// Documentation screenshots: the demo build renders its own windows to PNG and quits.
    /// Rendering in-process needs no Screen Recording permission, so it also works over SSH.
    private func captureSnapshotIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard Bundle.main.bundleIdentifier == "local.claudemirror.demo", let output = environment["MIRROR_SNAPSHOT"] else { return }
        if environment["MIRROR_APPEARANCE"] == "dark" { NSApp.appearance = NSAppearance(named: .darkAqua) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            if let size = environment["MIRROR_WINDOW"]?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
                NSApp.windows.first { $0.isVisible && $0.sheetParent == nil }?.setContentSize(NSSize(width: size[0], height: size[1]))
            }
            switch environment["MIRROR_SCENE"] {
            case "connect": self?.model?.showConnect = true
            case "home": self?.model?.activeId = nil
            case "files": self?.model?.showFiles = true
            default: break
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5) {
            for (index, window) in NSApp.windows.enumerated() where window.isVisible {
                let name = window.sheetParent == nil ? "window" : "sheet"
                guard let image = Self.windowImage(window) else { continue }
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: "\(output)-\(name)-\(index).png"))
            }
            // terminate(_:) can be held up by an open sheet; the demo has nothing to save.
            exit(0)
        }
    }

    /// The window server composites SwiftUI lists and materials that cacheDisplay leaves blank.
    /// CGWindowListCreateImage is unavailable to Swift on recent SDKs but still exported, and an
    /// app may capture its own windows; layer rendering is the fallback.
    private static func windowImage(_ window: NSWindow) -> CGImage? {
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage"),
           let image = unsafeBitCast(symbol, to: Capture.self)(.null, 1 << 3, UInt32(window.windowNumber), 1 | 1 << 3)?.takeRetainedValue(),
           image.width > 1 {
            return image
        }
        guard let view = window.contentView?.superview, let layer = view.layer else { return nil }
        let scale = window.backingScaleFactor
        let width = Int(view.bounds.width * scale), height = Int(view.bounds.height * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        layer.render(in: context)
        return context.makeImage()
    }
    #endif

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { @MainActor in model?.markActiveRead() }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if let id = response.notification.request.content.userInfo["sessionId"] as? String {
            Task { @MainActor in self.model?.select(id); NSApp.activate(ignoringOtherApps: true) }
        }
        completionHandler()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        if model.hasUnsavedEdits {
            let alert = NSAlert()
            alert.messageText = "远端文件有未保存的修改"
            alert.informativeText = "退出后这些编辑将丢失。"
            alert.addButton(withTitle: "继续编辑")
            alert.addButton(withTitle: "放弃修改")
            if alert.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        }
        model.shutdown()
        return .terminateNow
    }
}
#else
// The core library builds and tests on Linux; the interface needs macOS.
@main
struct RemoteCCStub {
    static func main() { print("RemoteCC 的界面只能在 macOS 上运行") }
}
#endif
