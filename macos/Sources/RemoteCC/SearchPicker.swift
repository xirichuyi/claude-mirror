#if canImport(SwiftUI)
import SwiftUI

struct SearchPickerItem: Identifiable {
    let id: String
    let title: String
    var detail: String = ""
}

/// Search-first selection, shared by remote commands and models.
struct SearchPicker: View {
    let title: String
    let items: [SearchPickerItem]
    var selected: String? = nil
    let refresh: () -> Void
    let choose: (String) -> Void
    @State private var query = ""
    @State private var selection: String?
    @FocusState private var focused: Bool

    private var results: [SearchPickerItem] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return items }
        let normalized = term.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        func rank(_ item: SearchPickerItem) -> Int {
            let title = item.title.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if title == normalized { return 0 }
            if title.hasPrefix(normalized) { return 1 }
            if title.contains(normalized) { return 2 }
            return item.detail.localizedCaseInsensitiveContains(term) ? 3 : 4
        }
        return items.enumerated().filter { rank($0.element) < 4 }
            .sorted { rank($0.element) == rank($1.element) ? $0.offset < $1.offset : rank($0.element) < rank($1.element) }
            .map(\.element)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索" + title, text: $query).textFieldStyle(.plain).focused($focused)
                    .onSubmit { if let item = results.first(where: { $0.id == selection }) ?? results.first { choose(item.id) } }
                    .onMoveCommand { direction in
                        guard !results.isEmpty else { return }
                        let index = results.firstIndex { $0.id == selection } ?? -1
                        if direction == .down { selection = results[min(index + 1, results.count - 1)].id }
                        if direction == .up { selection = results[max(index - 1, 0)].id }
                    }
            }.padding(14)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        if results.isEmpty {
                            Text(items.isEmpty ? "列表尚未加载，请刷新" : "没有匹配结果")
                                .font(.callout).foregroundStyle(.secondary).padding(24)
                        }
                        ForEach(results) { item in
                            Button { choose(item.id) } label: {
                                HStack(spacing: 10) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.title).font(.callout.weight(.medium))
                                        if !item.detail.isEmpty { Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                                    }
                                    Spacer()
                                    if selected == item.id { Image(systemName: "checkmark").foregroundStyle(WorkbenchTheme.sage) }
                                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                    .background(selection == item.id ? WorkbenchTheme.userBubble : .clear, in: RoundedRectangle(cornerRadius: 8))
                            }.buttonStyle(.plain).id(item.id)
                        }
                    }.padding(6)
                }.frame(maxHeight: 300)
                    .onChange(of: selection) { if let selection { proxy.scrollTo(selection) } }
            }
            Divider()
            HStack {
                Text("↑ ↓ 选择 · Enter 确认").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("刷新", action: refresh).buttonStyle(.borderless)
            }.padding(12)
        }
        .frame(width: 360).background(WorkbenchTheme.canvas)
        .onAppear { focused = true; selection = selected ?? results.first?.id }
        .onChange(of: query) { selection = results.first?.id }
    }
}
#endif
