import SwiftUI

/// User-triggered motion only. Streaming and viewport updates stay unanimated.
enum Motion {
    static let dialogIn = 0.22
    static let dialogOut = 0.15
    static let tree = 0.16
    static let slide = 0.15
    static let hover = 0.12
    static let scroll = 0.2

    static func animation(_ duration: Double, reduce: Bool) -> Animation? {
        reduce ? nil : .easeOut(duration: duration)
    }

    static func card(reduce: Bool) -> AnyTransition {
        guard !reduce else { return .identity }
        return .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.95)).animation(.easeOut(duration: dialogIn)),
            removal: .opacity.combined(with: .scale(scale: 0.98)).animation(.easeIn(duration: dialogOut)))
    }

    static func disclosure(reduce: Bool) -> AnyTransition {
        reduce ? .identity : .opacity.combined(with: .move(edge: .top))
    }

    static func tab(reduce: Bool) -> AnyTransition {
        reduce ? .identity : .opacity.combined(with: .move(edge: .leading))
    }
}
