#if canImport(SwiftUI)
import SwiftUI
import AppKit
import SwiftTerm
import RemoteCCCore

/// One shell per machine and folder. It keeps running while the panel is hidden.
final class TerminalSession: NSObject, ObservableObject, LocalProcessTerminalViewDelegate {
    let key: String
    let directory: String
    let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 240))
    @Published private(set) var ended = false
    private lazy var clipboard = ClipboardGuard(view)
    private let launch: () -> (executable: String, arguments: [String])?

    init(key: String, directory: String, launch: @escaping () -> (executable: String, arguments: [String])?) {
        self.key = key
        self.directory = directory
        self.launch = launch
        super.init()
        view.processDelegate = self
        view.terminalDelegate = clipboard
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        view.nativeBackgroundColor = .textBackgroundColor
        view.nativeForegroundColor = .textColor
    }

    func start() {
        guard let target = launch() else { ended = true; return }
        ended = false
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        view.startProcess(executable: target.executable, args: target.arguments, environment: environment.map { "\($0.key)=\($0.value)" }, execName: "ssh")
    }

    func terminate() { if !ended { view.terminate() } }

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async { self.ended = true }
    }
}

/// The server may not read the Mac's clipboard, and may set it only while the shell has the focus.
private final class ClipboardGuard: TerminalViewDelegate {
    private weak var view: LocalProcessTerminalView?
    init(_ view: LocalProcessTerminalView) { self.view = view }

    func clipboardRead(source: TerminalView) -> Data? { nil }
    func clipboardCopy(source: TerminalView, content: Data) {
        guard let view, let window = view.window, window.isKeyWindow, window.firstResponder === view else { return }
        view.clipboardCopy(source: source, content: content)
    }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) { view?.sizeChanged(source: source, newCols: newCols, newRows: newRows) }
    func setTerminalTitle(source: TerminalView, title: String) { view?.setTerminalTitle(source: source, title: title) }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) { view?.hostCurrentDirectoryUpdate(source: source, directory: directory) }
    func send(source: TerminalView, data: ArraySlice<UInt8>) { view?.send(source: source, data: data) }
    func scrolled(source: TerminalView, position: Double) { view?.scrolled(source: source, position: position) }
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) { view?.requestOpenLink(source: source, link: link, params: params) }
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) { view?.rangeChanged(source: source, startY: startY, endY: endY) }
}

struct TerminalPanel: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var session: TerminalSession

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                WorkbenchIcon(symbol: "terminal").foregroundStyle(WorkbenchTheme.inkMuted)
                Text((session.directory as NSString).lastPathComponent)
                    .font(.system(size: 11)).foregroundStyle(WorkbenchTheme.inkMuted)
                    .lineLimit(1).truncationMode(.middle).help(session.directory)
                Spacer(minLength: 4)
                if session.ended {
                    Button { session.start() } label: { WorkbenchIcon(symbol: "arrow.clockwise") }
                        .help("重新打开").accessibilityLabel("重新打开")
                }
                Button { model.closeTerminal() } label: { WorkbenchIcon(symbol: "xmark") }
                    .help("关闭终端").accessibilityLabel("关闭终端")
            }
            .buttonStyle(WorkbenchIconButtonStyle()).padding(.horizontal, 10).frame(height: 30)
            TerminalHost(view: session.view).padding(.leading, 6)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// The terminal view is owned by its session, so SwiftUI only borrows it.
private struct TerminalHost: NSViewRepresentable {
    let view: LocalProcessTerminalView

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ container: NSView, context: Context) {
        // The container is reused across projects; only the current session's view stays in it.
        for other in container.subviews where other !== view { other.removeFromSuperview() }
        guard view.superview !== container else { return }
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
    }
}
#endif
