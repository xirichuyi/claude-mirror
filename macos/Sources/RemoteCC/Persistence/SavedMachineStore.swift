import Foundation
import RemoteCCCore

/// Keeps removed hosts out of discovery without deleting their conversation history.
struct SavedMachineStore {
    private let defaults: UserDefaults
    private let savedKey = "saved-machines"
    private let removedKey = "removed-machines"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var removedKeys: Set<String> {
        Set(defaults.stringArray(forKey: removedKey) ?? [])
    }

    func load(discovered: [ConnectionConfig]) -> [ConnectionConfig] {
        let saved =
            defaults.data(forKey: savedKey)
            .flatMap { try? JSONDecoder().decode([ConnectionConfig].self, from: $0) } ?? []
        var seen = removedKeys
        return (saved + discovered).filter { seen.insert($0.key).inserted }
    }

    func save(_ machines: [ConnectionConfig]) {
        defaults.set(try? JSONEncoder().encode(machines), forKey: savedKey)
    }

    func markRemoved(_ key: String) {
        defaults.set(Array(removedKeys.union([key])), forKey: removedKey)
    }

    func allow(_ key: String) {
        defaults.set(Array(removedKeys.subtracting([key])), forKey: removedKey)
    }
}
