import Foundation
import RemoteCCCore

/// Opening Home does not erase the last conversation. Missing or archived entries fall back
/// to the most recently updated visible conversation, including its original server.
struct RecentConversation {
    private let defaults: UserDefaults
    private let key = "last-opened-conversation"

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func remember(_ id: String?) {
        guard let id else { return }
        defaults.set(id, forKey: key)
    }

    func resolve(in sessions: [ChatSession]) -> String? {
        let visible = sessions.filter { $0.archived != true }
        if let id = defaults.string(forKey: key), visible.contains(where: { $0.id == id }) { return id }
        return visible.max { $0.updatedAt < $1.updatedAt }?.id
    }
}
