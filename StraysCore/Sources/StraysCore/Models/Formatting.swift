import Foundation

/// Compact, glanceable text for durations and sizes.
public enum StraysFormat {
    /// `45s`, `12m`, `3h 12m`, `2d 4h`.
    public static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 { return hours > 0 ? "\(days)d \(hours)h" : "\(days)d" }
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        if minutes > 0 { return "\(minutes)m" }
        return "\(total)s"
    }

    public static func uptime(since start: Date?, now: Date = Date()) -> String {
        guard let start else { return "–" }
        return duration(now.timeIntervalSince(start))
    }

    /// `812 KB`, `312 MB`, `1.4 GB`.
    public static func memory(_ bytes: UInt64) -> String {
        let megabytes = Double(bytes) / 1_048_576
        if megabytes < 1 { return "\(Int((Double(bytes) / 1_024).rounded())) KB" }
        if megabytes < 1_000 { return "\(Int(megabytes.rounded())) MB" }
        return String(format: "%.1f GB", megabytes / 1_024)
    }

    /// `0%`, `1.2%`, `48%`, `212%`.
    public static func cpu(_ percent: Double) -> String {
        if percent < 0.05 { return "0%" }
        if percent < 10 { return String(format: "%.1f%%", percent) }
        return "\(Int(percent.rounded()))%"
    }
}
