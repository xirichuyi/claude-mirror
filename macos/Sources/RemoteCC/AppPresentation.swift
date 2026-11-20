import SwiftUI
import RemoteCCCore

/// Only one application sheet can be presented at a time.
enum AppPresentation: Identifiable {
    case account
    case confirmation(WorkbenchConfirmation)
    case rename(WorkbenchRename)
    case fileName(NamePrompt, Workspace)
    case rewind(session: String, checkpoint: String)
    case accountUsage
    case worktree
    case usage
    case activity
    case connect
    case editMachine(ConnectionConfig)
    case remoteSetup(ConnectionConfig)
    case keyLogin(ConnectionConfig)
    case projectPicker
    case settings
    case preferences
    case quickOpen
    case sessionTools
    case chatGallery
    case command(CommandInteraction)
    var id: String {
        switch self {
        case .fileName(let prompt, _): return "file:" + prompt.id.uuidString
        case .rewind(let session, let checkpoint): return "rewind:" + session + checkpoint
        case .confirmation(let request): return "confirm:" + request.id.uuidString
        case .rename(let request): return "rename:" + request.id.uuidString
        case .account: return "account"
        case .accountUsage: return "accountUsage"
        case .worktree: return "worktree"
        case .usage: return "usage"
        case .activity: return "activity"
        case .editMachine(let config): return "editMachine:" + config.key
        case .connect: return "connect"
        case .remoteSetup(let config): return "remoteSetup:" + config.key
        case .keyLogin(let config): return "keyLogin:" + config.key
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
            case .fileName(let prompt, let workspace): NameSheet(prompt: prompt, workspace: workspace)
            case .rewind(let session, let checkpoint): RewindSheet(sessionId: session, checkpoint: checkpoint)
            case .confirmation(let request): ConfirmationSheet(request: request)
            case .rename(let request): RenameSheet(request: request)
            case .account: AccountStatusSheet(store: model.accountStore)
            case .accountUsage: AccountUsageSheet()
            case .worktree: WorktreeSheet()
            case .usage: UsageSheet()
            case .activity: ActivitySheet()
            case .connect: ConnectSheet()
            case .editMachine(let config): ConnectSheet(machine: config)
            case .remoteSetup(let config): RemoteSetupSheet(machine: config)
            case .keyLogin(let config): KeyLoginSheet(machine: config)
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

/// Application modals share the same scrim, border and motion. Native file/password dialogs
/// remain native; their security and file-selection behavior belongs to macOS.
struct WorkbenchPresentationLayer: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            if let destination = model.presentation {
                ZStack {
                    WorkbenchTheme.scrim.ignoresSafeArea().contentShape(Rectangle())
                        .onTapGesture { } // Do not discard an in-progress form on an outside click.
                    ScrollView(.vertical) {
                        AppSheet(destination: destination).id(destination.id)
                            .background(WorkbenchTheme.popup)
                            .clipShape(RoundedRectangle(cornerRadius: WorkbenchMetrics.dialogRadius))
                            .overlay(RoundedRectangle(cornerRadius: WorkbenchMetrics.dialogRadius).strokeBorder(WorkbenchTheme.popupBorder))
                            .shadow(color: WorkbenchTheme.shadow, radius: 24, y: 10)
                            .padding(24)
                            .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .scrollBounceBehavior(.basedOnSize)
                    .transition(Motion.card(reduce: reduceMotion))
                }
                .accessibilityAddTraits(.isModal)
            }
        }
        .animation(Motion.animation(Motion.dialogIn, reduce: reduceMotion), value: model.presentation?.id)
    }
}
