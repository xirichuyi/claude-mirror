import SwiftUI
import AppKit
import RemoteCCCore

/// Formats come from Winc's image::is_image/is_svg, table and markdown modules.
enum FilePreviewSupport {
    static func hasVisualPreview(_ name: String) -> Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "bmp", "ico", "cur", "svg",
         "csv", "tsv", "tab", "xlsx", "xlsm", "md", "markdown", "mdown", "mkd", "mkdn"]
            .contains((name as NSString).pathExtension.lowercased())
    }
}

/// Remote transport and lifetime only. All format parsing/decoding runs in unmodified Winc Rust.
struct RemoteDocumentPreview: View {
    let preview: FilePreview
    let workspace: Workspace
    @EnvironmentObject private var model: AppModel
    @State private var document: JSON?
    @State private var image: NSImage?
    @State private var folder: URL?
    @State private var error: String?
    @State private var requested = false
    @State private var retry = UUID()
    @State private var sheetIndex = 0

    var body: some View {
        Group {
            if let document {
                switch document["kind"]?.string {
                case "image":
                    if let image { WincPictureView(image: image, document: document) }
                case "table":
                    let sheets = document["sheets"]?.array ?? []
                    VStack(spacing: 0) {
                        if sheets.indices.contains(sheetIndex) {
                            WincTableView(sheet: sheets[sheetIndex])
                            if sheets[sheetIndex]["truncated"]?.bool == true {
                                Text("已达到 Winc 预览行列上限").font(.caption).foregroundStyle(WorkbenchTheme.inkMuted)
                            }
                        }
                        if sheets.count > 1 {
                            ScrollView(.horizontal) {
                                HStack(spacing: 2) {
                                    ForEach(sheets.indices, id: \.self) { index in
                                        Button(sheets[index]["name"]?.string ?? "Sheet \(index + 1)") { sheetIndex = index }
                                            .buttonStyle(QuietButtonStyle())
                                            .background(sheetIndex == index ? WorkbenchTheme.selected : .clear, in: RoundedRectangle(cornerRadius: 5))
                                    }
                                }.padding(6)
                            }.fixedSize(horizontal: false, vertical: true)
                        }
                    }
                case "markdown":
                    ScrollView {
                        let content = WincMarkdownAdapter.document(document["blocks"]?.array ?? [])
                        SelectableTranscriptText(text: content.string, attributed: content, scope: nil) { url in
                            if ["http", "https"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
                            else if let reference = RemoteFileLinks.reference(url) {
                                let path = reference.path.hasPrefix("/") || reference.path.hasPrefix("~") ? reference.path : (preview.path as NSString).deletingLastPathComponent + "/" + reference.path
                                model.open(path, line: reference.line)
                            }
                        }.padding(24)
                    }
                default: EmptyView()
                }
            } else if let error {
                VStack(spacing: 10) {
                    Text(error).font(.caption).foregroundStyle(WorkbenchTheme.inkMuted).textSelection(.enabled)
                    Button("重试预览") { retry = UUID() }
                }.padding(20)
            } else if preview.size > 32 * 1024 * 1024 && !requested {
                Button("加载预览（\(ByteCountFormatter.string(fromByteCount: Int64(preview.size), countStyle: .file))）") { requested = true }
            } else { ProgressView().controlSize(.small) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: "\(preview.path)|\(preview.version ?? "")|\(requested)|\(retry)") {
            cleanup(); error = nil; sheetIndex = 0
            guard preview.size <= 32 * 1024 * 1024 || requested else { return }
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("remotecc-winc-" + UUID().uuidString)
            let url = folder.appendingPathComponent((preview.path as NSString).lastPathComponent)
            do {
                guard preview.size <= 256 * 1024 * 1024 else { throw RemoteError("超过 Winc 预览文件大小上限（256 MB）") }
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try await workspace.downloadPreview(preview.path, to: url)
                let result = try await WincPreviewBridge.load(url, output: folder.appendingPathComponent("rendered"))
                try Task.checkCancellation()
                if result["kind"]?.string == "image" {
                    image = NSImage(contentsOf: folder.appendingPathComponent("rendered/image.png"))
                    guard image != nil else { throw RemoteError("无法读取 Winc 渲染结果") }
                }
                self.folder = folder; document = result
            } catch {
                try? FileManager.default.removeItem(at: folder)
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
        .onDisappear { cleanup() }
    }
    private func cleanup() {
        document = nil; image = nil
        if let folder { try? FileManager.default.removeItem(at: folder) }
        folder = nil
    }
}

private enum WincPreviewBridge {
    static func load(_ file: URL, output: URL) async throws -> JSON {
        guard let executable = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("WincPreview"),
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw RemoteError("Winc 预览组件缺失，请重新构建应用")
        }
        let process = try RemoteProcess(executable: executable.path, arguments: [file.path, output.path])
        process.closeInput()
        return try await withTaskCancellationHandler {
            let code = await process.waitForExit()
            try Task.checkCancellation()
            guard code == 0 else { throw RemoteError(process.stderrText.isEmpty ? "Winc 预览失败" : process.stderrText) }
            return try await Task.detached(priority: .userInitiated) {
                try JSONDecoder().decode(JSON.self, from: Data(contentsOf: output.appendingPathComponent("result.json")))
            }.value
        } onCancel: { process.kill() }
    }
}

private struct WincPictureView: View {
    let image: NSImage
    let document: JSON
    @State private var actualSize = false
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button("适应窗口") { actualSize = false }
                    .background(!actualSize ? WorkbenchTheme.selected : .clear, in: RoundedRectangle(cornerRadius: 4))
                Button("100%") { actualSize = true }
                    .background(actualSize ? WorkbenchTheme.selected : .clear, in: RoundedRectangle(cornerRadius: 4))
                Spacer()
                Text("\(document["width"]?.int ?? 0) × \(document["height"]?.int ?? 0)").foregroundStyle(WorkbenchTheme.inkMuted)
            }.font(.caption).buttonStyle(QuietButtonStyle()).padding(6)
            GeometryReader { proxy in
                if actualSize {
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: image).resizable()
                            .frame(width: CGFloat(document["width"]?.int ?? 1), height: CGFloat(document["height"]?.int ?? 1))
                            .frame(minWidth: proxy.size.width, minHeight: proxy.size.height)
                    }
                } else {
                    Image(nsImage: image).resizable().scaledToFit().padding(24)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                }
            }
            if let missing = document["missing"]?.array, !missing.isEmpty {
                Text("未显示：" + missing.compactMap(\.string).joined(separator: "、"))
                    .font(.caption).foregroundStyle(WorkbenchTheme.inkMuted).padding(6)
            }
        }.background(WorkbenchTheme.surface)
    }
}

/// Native view adapter only; cells, dates, formats and worksheet limits come from Winc.
private struct WincTableView: NSViewRepresentable {
    let sheet: JSON
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        let table = NSTableView()
        table.dataSource = context.coordinator; table.delegate = context.coordinator
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 24; table.columnAutoresizingStyle = .noColumnAutoresizing
        scroll.documentView = table
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard context.coordinator.sheet != sheet, let table = scroll.documentView as? NSTableView else { return }
        context.coordinator.sheet = sheet
        context.coordinator.rows = (sheet["rows"]?.array ?? []).map { ($0.array ?? []).map { $0.string ?? "" } }
        table.tableColumns.forEach { table.removeTableColumn($0) }
        let count = sheet["columns"]?.int ?? 0
        let labels = sheet["labels"]?.array ?? []
        for index in 0..<count {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(String(index)))
            column.title = index < labels.count ? labels[index].string ?? "" : String(index + 1)
            column.width = 160; column.minWidth = 60
            table.addTableColumn(column)
        }
        table.reloadData()
    }
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var sheet: JSON?
        var rows: [[String]] = []
        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let column = tableColumn.flatMap({ Int($0.identifier.rawValue) }) else { return nil }
            let id = NSUserInterfaceItemIdentifier("cell")
            let label = tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField ?? NSTextField(labelWithString: "")
            label.identifier = id; label.font = .systemFont(ofSize: 12); label.isSelectable = true
            label.lineBreakMode = .byTruncatingTail
            label.stringValue = column < rows[row].count ? rows[row][column] : ""
            label.toolTip = label.stringValue
            return label
        }
    }
}

/// Converts Winc's already-parsed AST to the macOS text system. No Markdown parser here.
private enum WincMarkdownAdapter {
    static func document(_ blocks: [JSON], indent: CGFloat = 0) -> NSAttributedString {
        let output = NSMutableAttributedString(string: "")
        for block in blocks {
            let kind = block["kind"]?.string ?? ""
            let paragraph = NSMutableParagraphStyle()
            paragraph.headIndent = indent; paragraph.firstLineHeadIndent = indent
            paragraph.paragraphSpacing = 12; paragraph.lineSpacing = 4
            var attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSTheme.text, .paragraphStyle: paragraph]
            switch kind {
            case "heading":
                attributes[.font] = NSFont.systemFont(ofSize: CGFloat(max(14, 26 - (block["level"]?.int ?? 1) * 2)), weight: .semibold)
                output.append(inline(block["inline"] ?? .null, attributes: attributes))
            case "paragraph", "details":
                output.append(inline(block["inline"] ?? .null, attributes: attributes))
                if kind == "details" { output.append(document(block["blocks"]?.array ?? [], indent: indent + 16)) }
            case "quote", "footnote": output.append(document(block["blocks"]?.array ?? [], indent: indent + 16))
            case "list":
                for (index, item) in (block["items"]?.array ?? []).enumerated() {
                    let prefix: String
                    if let task = item["task"]?.bool { prefix = task ? "☑ " : "☐ " }
                    else if let start = block["start"]?.int { prefix = "\(start + index). " }
                    else { prefix = "• " }
                    output.append(NSAttributedString(string: prefix, attributes: attributes))
                    output.append(document(item["blocks"]?.array ?? [], indent: indent + 16))
                }
            case "table":
                for row in block["rows"]?.array ?? [] {
                    for (index, cell) in (row.array ?? []).enumerated() {
                        if index > 0 { output.append(NSAttributedString(string: "\t", attributes: attributes)) }
                        output.append(inline(cell, attributes: attributes))
                    }
                    output.append(NSAttributedString(string: "\n", attributes: attributes))
                }
            case "rule": output.append(NSAttributedString(string: "────────────────", attributes: attributes))
            default:
                attributes[.font] = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
                output.append(NSAttributedString(string: block["text"]?.string ?? "", attributes: attributes))
            }
            output.append(NSAttributedString(string: "\n", attributes: attributes))
        }
        return output
    }
    static func inline(_ value: JSON, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let output = NSMutableAttributedString(string: "")
        let runs = value["runs"]?.array ?? []
        if runs.isEmpty { return NSAttributedString(string: value["text"]?.string ?? "", attributes: attributes) }
        let images = value["images"]?.array ?? []
        var imageIndex = 0
        for run in runs {
            var attrs = attributes
            let flags = run["flags"]?.int ?? 0
            var font = attrs[.font] as? NSFont ?? .systemFont(ofSize: 13)
            if flags & 1 != 0 { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            if flags & 2 != 0 { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            if flags & 8 != 0 { font = .monospacedSystemFont(ofSize: 12, weight: .regular); attrs[.backgroundColor] = NSTheme.surface }
            attrs[.font] = font
            if flags & 4 != 0 { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run["link"]?.string, let url = URL(string: link) { attrs[.link] = url; attrs[.foregroundColor] = NSTheme.accent }
            let parts = (run["text"]?.string ?? "").components(separatedBy: "\u{FFFC}")
            for (index, part) in parts.enumerated() {
                if index > 0, images.indices.contains(imageIndex) {
                    let image = images[imageIndex]
                    var imageAttributes = attrs
                    if let url = image["url"]?.string.flatMap(URL.init(string:)) { imageAttributes[.link] = url; imageAttributes[.foregroundColor] = NSTheme.accent }
                    let alt = image["alt"]?.string ?? ""
                    output.append(NSAttributedString(string: alt.isEmpty ? "图片" : alt, attributes: imageAttributes))
                    imageIndex += 1
                }
                output.append(NSAttributedString(string: part, attributes: attrs))
            }
        }
        return output
    }
}
