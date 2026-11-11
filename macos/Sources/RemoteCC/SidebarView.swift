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
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    if searchExpanded {
                        TextField("搜索对话", text: $model.searchText)
                            .textFieldStyle(.plain).focused($searchFocused)
                            .task { await Task.yield(); searchFocused = true }
                            .onExitCommand { closeSearch() }
                    } else {
                        Text(model.showArchived ? "已归档" : "项目").font(.system(size: 13, weight: .semibold))
                    }
                    Spacer(minLength: 0)
                }.padding(.horizontal, 12).frame(height: 32)
                HStack(spacing: 2) {
                    Button { model.newConversation() } label: { WorkbenchIcon(symbol: "square.and.pencil") }
                        .help("新建对话（⌘N）").accessibilityLabel("新建对话").disabled(model.currentConfig == nil)
                    Button { model.openProjectPicker() } label: { WorkbenchIcon(symbol: "folder.badge.plus") }
                        .help("打开或新建项目").accessibilityLabel("打开或新建项目").disabled(!model.isConnected)
                    HistorySyncButton()
                    Spacer(minLength: 0)
                    Button { if searchExpanded { closeSearch() } else { searchExpanded = true } } label: {
                        WorkbenchIcon(symbol: searchExpanded ? "xmark" : "magnifyingglass")
                    }.help(searchExpanded ? "关闭搜索" : "搜索对话").accessibilityLabel(searchExpanded ? "关闭搜索" : "搜索对话")
                }.buttonStyle(WorkbenchIconButtonStyle(size: 24))
                    .padding(.horizontal, 8).frame(height: 28)
            }
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
                    }
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
        }
        .background { FrostedBackground() }
        .foregroundStyle(WorkbenchTheme.sidebarInk)
    }

    private func closeSearch() {
        model.searchText = ""
        searchExpanded = false
        searchFocused = false
    }


}
#endif
