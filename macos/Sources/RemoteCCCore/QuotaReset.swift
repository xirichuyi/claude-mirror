import Foundation

public enum QuotaReset {
    public static func date(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
    }

    public static func countdown(until reset: Date, now: Date) -> String {
        let seconds = reset.timeIntervalSince(now)
        guard seconds > 0 else { return "已到重置时间，等待更新" }
        let minutes = Int(ceil(seconds / 60))
        let days = minutes / 1440
        let hours = (minutes % 1440) / 60
        let remainder = minutes % 60
        if days > 0 { return "\(days)天 \(hours)小时后重置" }
        if hours > 0 { return "\(hours)小时 \(remainder)分钟后重置" }
        return "\(minutes)分钟后重置"
    }

    public static func localTime(_ date: Date, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = timeZone
        formatter.dateFormat = "M月d日 HH:mm zzz"
        return formatter.string(from: date)
    }
}
