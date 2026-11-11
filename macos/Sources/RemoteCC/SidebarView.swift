#if canImport(SwiftUI)
import SwiftUI
import AppKit
import RemoteCCCore

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showAllProjects = false
    @State private var searchExpanded = false
    @FocusState private var searchFocused: Bool

    private var groups: [(key: String, sessions: [ChatSession])] {
        let filter = model.searchText.lowercased()
        let visible = model.machineSessions.filter { ($0.archived ?? false) == model.showArchived }.filter {
            filter.isEmpty || "\($0.name) \($0.host) \($0.directory) \($0.historySummary ?? "")".lowercased().contains(filter)
        }
        var order: [String] = [], grouped: [String: [ChatSession]] = [:]
        for session in visible {
            if grouped[session.projectKey] == nil { order.append(session.projectKey) }
            grouped[session.projectKey, default: []].append(session)
        }
        return order.map { ($0, grouped[$0]!) }.filter { !model.projectMissing($0.1[0]) }
    }

    private var unavailableSessions: [ChatSession] {
        model.machineSessions.filter {
            model.projectMissing($0) && ($0.archived ?? false) == model.showArchived &&
            (model.searchText.isEmpty || ($0.name + " " + $0.directory).localizedCaseInsensitiveContains(model.searchText))
        }
    }

    private var visibleGroups: [(key: String, sessions: [ChatSession])] {
        if showAllProjects || !model.searchText.isEmpty { return groups }
        var result = Array(groups.prefix(6))
        if let active = groups.first(where: { $0.sessions.contains(where: { $0.id == model.activeId }) }), !result.contains(where: { $0.key == active.key }) { result.append(active) }
        return result
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                // The most common action gets a label and its shortcut; search sits beside it.
                HStack(spacing: 4) {
                    Button { model.newConversation() } label: {
                        HStack(spacing: 7) {
                            WorkbenchIcon(symbol: "square.and.pencil")
                            Text("新对话").font(.system(size: 13, weight: .medium))
                            Spacer(minLength: 4)
                            Text("⌘N").font(.system(size: 11)).foregroundStyle(WorkbenchTheme.inkDim)
                        }
                    }
                    .buttonStyle(SidebarNavigationStyle())
                    .disabled(model.currentConfig == nil)
                    .help("新建对话（⌘N）").accessibilityLabel("新建对话")
                    Button {
                        if searchExpanded { closeSearch() }
                        else { searchExpanded = true }
                    } label: { WorkbenchIcon(symbol: "magnifyingglass") }
                        .buttonStyle(WorkbenchIconButtonStyle(selected: searchExpanded)).help("搜索对话")
                        .accessibilityLabel("搜索对话")
                }
                if searchExpanded {
                    HStack(spacing: 7) {
                        WorkbenchIcon(symbol: "magnifyingglass").foregroundStyle(WorkbenchTheme.inkMuted)
                        TextField("搜索对话", text: $model.searchText)
                            .textFieldStyle(.plain).focused($searchFocused)
                            .task { await Task.yield(); searchFocused = true }
                            .onExitCommand { closeSearch() }
                        Button { closeSearch() } label: { WorkbenchIcon(symbol: "xmark") }
                            .buttonStyle(.plain).help("关闭搜索").accessibilityLabel("关闭搜索")
                    }
                    .font(.callout).padding(9)
                    .background(WorkbenchTheme.ink.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                if !groups.isEmpty {
                    Section {
                        ForEach(Array(visibleGroups.enumerated()), id: \.element.key) { index, group in
                            ProjectGroup(sessions: group.sessions, searching: !model.searchText.isEmpty, initiallyExpanded: index < 2)
                        }
                        if model.searchText.isEmpty && (showAllProjects || groups.count > visibleGroups.count) {
                            Button(showAllProjects ? "收起项目" : "更多项目（\(groups.count - visibleGroups.count)）") { showAllProjects.toggle() }
                                .buttonStyle(.borderless).foregroundStyle(WorkbenchTheme.inkMuted).font(.system(size: 12))
                                .padding(.leading, 22).frame(height: 24)
                        }
                    } header: { projectsHeader }
                }
                if !unavailableSessions.isEmpty {
                    Section {
                        ProjectGroup(sessions: unavailableSessions, searching: !model.searchText.isEmpty, flat: true)
                    } header: { SidebarSectionHeader(title: "目录已移除 · 历史对话") }
                }
                }.padding(.horizontal, 6).padding(.bottom, 8)

            }
            .id(model.currentConfig?.key ?? "no-machine")
            .frame(maxHeight: .infinity)
            .overlay(alignment: .topLeading) {
                if groups.isEmpty && unavailableSessions.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.searchText.isEmpty ? (model.showArchived ? "还没有归档的对话" : "暂无历史对话") : "没有找到匹配的对话")
                    }
                    .font(.subheadline).foregroundStyle(WorkbenchTheme.inkMuted)
                    .padding(.horizontal, 20).padding(.top, 20).allowsHitTesting(false)
                }
            }
            ServerFooter()
        }
        .background { FrostedBackground() }
        .foregroundStyle(WorkbenchTheme.sidebarInk)
    }

    /// Section title with its own actions, so they sit next to the list they change.
    private var projectsHeader: some View {
        HStack(spacing: 2) {
            SidebarSectionHeader(title: model.showArchived ? "已归档 · 项目" : "项目")
            Button { model.openProjectPicker() } label: { WorkbenchIcon(symbol: "folder.badge.plus") }
                .buttonStyle(WorkbenchIconButtonStyle(size: 22)).help("打开或新建项目").accessibilityLabel("打开或新建项目")
                .disabled(!model.isConnected)
            HistorySyncButton()
        }.padding(.trailing, 2).padding(.top, 4)
    }

    private func closeSearch() {
        model.searchText = ""
        searchExpanded = false
        searchFocused = false
    }


}
#endif
