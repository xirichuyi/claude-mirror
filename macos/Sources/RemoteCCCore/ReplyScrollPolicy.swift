import Foundation

public enum ReplyScrollPolicy {
    /// Small wheel movements and layout rounding must not expose a jump control.
    public static func showsJump(distance: Double, following: Bool) -> Bool {
        !following && distance > 180
    }
    public static func isNearBottom(_ distance: Double) -> Bool { distance <= 24 }
}
