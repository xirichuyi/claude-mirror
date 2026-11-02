import Foundation

/// A newer published release of this app.
public struct AppUpdate: Equatable, Sendable {
    public var version: String
    public var pageURL: URL
    /// The DMG for this Mac's architecture, when the release has one.
    public var downloadURL: URL?
    public var notes: String
}

/// Checks GitHub Releases. It only reports; installing stays a user action because the app is not notarized.
public enum UpdateChecker {
    public static let repository = "xirichuyi/claude-mirror"
    public static let latestURL = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    private static let trustedPrefix = "https://github.com/\(repository)/"

    public static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "x86_64"
        #endif
    }

    /// "v0.17.0" → [0, 17, 0]; pre-release or malformed tags are not offered as updates.
    public static func versionParts(_ text: String) -> [Int]? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("v") || value.hasPrefix("V") { value.removeFirst() }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        let numbers = parts.map { Int($0) }
        guard numbers.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        return numbers.map { $0! }
    }

    public static func isNewer(_ remote: String, than current: String) -> Bool {
        guard let remote = versionParts(remote), let current = versionParts(current) else { return false }
        for index in 0..<max(remote.count, current.count) {
            let left = index < remote.count ? remote[index] : 0
            let right = index < current.count ? current[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    private static func trusted(_ text: String?) -> URL? {
        guard let text, text.hasPrefix(trustedPrefix), let url = URL(string: text), url.scheme == "https", url.host == "github.com" else { return nil }
        return url
    }

    /// Reads the GitHub "latest release" response. Links outside this repository are refused.
    public static func parse(_ data: Data, architecture: String = architecture) -> AppUpdate? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String, versionParts(tag) != nil,
              object["draft"] as? Bool != true, object["prerelease"] as? Bool != true,
              let page = trusted(object["html_url"] as? String) else { return nil }
        let assets = object["assets"] as? [[String: Any]] ?? []
        let dmg = assets.first { ($0["name"] as? String)?.hasSuffix("-macOS-\(architecture).dmg") == true }
        let version = tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
        return AppUpdate(version: version, pageURL: page, downloadURL: trusted(dmg?["browser_download_url"] as? String),
                         notes: (object["body"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public static func fetchLatest(session: URLSession = .shared) async throws -> AppUpdate? {
        var request = URLRequest(url: latestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ClaudeMirror-UpdateCheck", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw RemoteError("检查更新失败：无效响应") }
        if status == 404 { return nil }
        guard status == 200 else { throw RemoteError("检查更新失败：GitHub 返回 \(status)") }
        return parse(data)
    }
}
