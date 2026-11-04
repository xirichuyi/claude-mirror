import SwiftUI
import RemoteCCCore

/// Only one application sheet can be presented at a time.
enum AppPresentation: Identifiable {
    case account
    case accountUsage
    case worktree
    case usage
    case activity
    case connect
    case projectPicker
    case settings
    case preferences
    case quickOpen
    case sessionTools
    case chatGallery
    case command(CommandInteraction)
    var id: String {
        switch self {
        case .account: return "account"
        case .accountUsage: return "accountUsage"
        case .worktree: return "worktree"
        case .usage: return "usage"
        case .activity: return "activity"
        case .connect: return "connect"
        case .projectPicker: return "projectPicker"
        case .settings: return "settings"
        case .preferences: return "preferences"
        case .quickOpen: return "quickOpen"
        case .sessionTools: return "sessionTools"
        case .chatGallery: return "chatGallery"
        case .command(let value): return "command:" + value.command
        }
    }
}

@MainActor
extension AppModel {
    var showWorktree: Bool {
        get { presentation?.id == "worktree" }
        set {
            if newValue { presentation = .worktree }
            else if showWorktree { presentation = nil }
        }
    }
    var showUsage: Bool {
        get { presentation?.id == "usage" }
        set {
            if newValue { presentation = .usage }
            else if showUsage { presentation = nil }
        }
    }
    var showActivity: Bool {
        get { presentation?.id == "activity" }
        set {
            if newValue { presentation = .activity }
            else if showActivity { presentation = nil }
        }
    }
    var showConnect: Bool {
        get { presentation?.id == "connect" }
        set {
            if newValue { presentation = .connect }
            else if showConnect { presentation = nil }
        }
    }
    var showProjectPicker: Bool {
        get { presentation?.id == "projectPicker" }
        set {
            if newValue { presentation = .projectPicker }
            else if showProjectPicker { presentation = nil }
        }
    }
    var showSettings: Bool {
        get { presentation?.id == "settings" }
        set {
            if newValue { presentation = .settings }
            else if showSettings { presentation = nil }
        }
    }
    var showPreferences: Bool {
        get { presentation?.id == "preferences" }
        set {
            if newValue { presentation = .preferences }
            else if showPreferences { presentation = nil }
        }
    }
    var showQuickOpen: Bool {
        get { presentation?.id == "quickOpen" }
        set {
            if newValue { presentation = .quickOpen }
            else if showQuickOpen { presentation = nil }
        }
    }
    var showSessionTools: Bool {
        get { presentation?.id == "sessionTools" }
        set {
            if newValue { presentation = .sessionTools }
            else if showSessionTools { presentation = nil }
        }
    }
    var showChatGallery: Bool {
        get { presentation?.id == "chatGallery" }
        set {
            if newValue { presentation = .chatGallery }
            else if showChatGallery { presentation = nil }
        }
    }
    var commandPicker: CommandInteraction? {
        get { if case .command(let value) = presentation { return value }; return nil }
        set {
            if let newValue { presentation = .command(newValue) }
            else if commandPicker != nil { presentation = nil }
        }
    }
}

struct AppSheet: View {
    @EnvironmentObject private var model: AppModel
    let destination: AppPresentation
    var body: some View {
        Group {
            switch destination {
            case .account: AccountStatusSheet(store: model.accountStore)
            case .accountUsage: AccountUsageSheet()
            case .worktree: WorktreeSheet()
            case .usage: UsageSheet()
            case .activity: ActivitySheet()
            case .connect: ConnectSheet()
            case .projectPicker: ProjectPickerSheet()
            case .settings: SettingsSheet()
            case .preferences: PreferencesSheet()
            case .quickOpen: QuickOpenSheet()
            case .sessionTools: SessionToolsSheet()
            case .chatGallery:
                #if DEBUG
                ChatGallery()
                #else
                EmptyView()
                #endif
            case .command(let value): CommandPickerSheet(interaction: value)
            }
        }.workbenchPanel()
    }
}
