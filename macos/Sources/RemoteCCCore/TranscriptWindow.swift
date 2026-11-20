import Foundation

/// A fixed-size, overlapping page. Its trailing ID keeps historical reading stable
/// when remote history is prepended or a new reply arrives.
public struct TranscriptWindow: Equatable {
    public static let capacity = 30
    public private(set) var endID: String?
    public init() {}
    public func range(in messages: [ChatMessage]) -> Range<Int> {
        let end = endID.flatMap { id in messages.firstIndex { $0.id == id }.map { $0 + 1 } } ?? messages.count
        return max(0, end - Self.capacity)..<end
    }
    public mutating func earlier(in messages: [ChatMessage]) {
        let current = range(in: messages)
        guard current.lowerBound > 0 else { return }
        let end = max(1, current.upperBound - 20)
        endID = messages[end - 1].id
    }
    public mutating func later(in messages: [ChatMessage]) {
        let end = min(messages.count, range(in: messages).upperBound + 20)
        endID = end == messages.count ? nil : messages[end - 1].id
    }
    public mutating func latest() { endID = nil }
    public mutating func pin(in messages: [ChatMessage]) {
        if endID == nil { endID = messages.last?.id }
    }
}
