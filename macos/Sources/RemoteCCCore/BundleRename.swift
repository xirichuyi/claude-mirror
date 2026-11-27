import Foundation

/// Sparkle updates an app in place, so an install from before the rename keeps its old file name.
public enum BundleRename {
    public static let currentName = "Tether.app"
    static let legacyNames: Set<String> = ["claude-mirror.app", "claude mirror.app"]

    /// Where an app still installed under an old name should move to, or nil when it should stay.
    public static func target(for bundle: URL) -> URL? {
        guard legacyNames.contains(bundle.lastPathComponent.lowercased()),
              !bundle.path.contains("/AppTranslocation/") else { return nil }
        return bundle.deletingLastPathComponent().appendingPathComponent(currentName)
    }
}
