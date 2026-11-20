import Foundation

/// The account facts worth showing. A field the remote Claude did not report is left out.
public enum AccountSummary {
    public struct Row: Hashable, Sendable {
        public var title: String
        public var value: String
    }

    static let providers = ["firstParty": "Anthropic", "bedrock": "Amazon Bedrock", "vertex": "Google Vertex AI",
                            "foundry": "Microsoft Foundry", "gateway": "企业网关"]

    public static func rows(_ status: JSON) -> [Row] {
        let account = status["account"]
        let provider = account?["apiProvider"]?.string
        return [
            ("邮箱", account?["email"]?.string),
            ("组织", account?["organization"]?.string),
            ("订阅", account?["subscriptionType"]?.string),
            ("服务提供方", provider.map { providers[$0] ?? $0 }),
            ("Claude Code", status["version"]?.string),
        ].compactMap { title, value in
            guard let value, !value.isEmpty else { return nil }
            return Row(title: title, value: value)
        }
    }
}
