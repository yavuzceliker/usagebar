import Foundation

enum Provider: String, CaseIterable, Identifiable {
    case cursor
    case claude

    var id: String { rawValue }
    var title: String { self == .cursor ? "Cursor" : "Claude" }

    var dashboardURL: URL {
        switch self {
        case .cursor: return URL(string: "https://cursor.com/dashboard?tab=usage")!
        case .claude: return URL(string: "https://claude.ai/settings/usage")!
        }
    }

    /// Seconds between API calls. Claude's usage endpoint rate-limits aggressively.
    var pollInterval: TimeInterval { self == .cursor ? 15 : 60 }
}

/// One signed-in account: a Cursor user-data dir or a Claude Code config dir.
struct Account: Identifiable, Hashable {
    let provider: Provider
    /// Cursor: path to state.vscdb. Claude: the config dir (~/.claude or ~/.claude-<name>).
    let source: String
    let isDefault: Bool
    let email: String?
    /// Short name taken from the folder, e.g. "work" for ~/.cursor-work.
    let name: String

    var id: String { "\(provider.rawValue):\(source)" }
    var title: String { email ?? name }
    /// Shown in the menu bar so you can tell which account is active.
    var tag: String { name }
}

struct UsageMeter: Identifiable {
    let id: String
    let label: String
    let percent: Double?   // 0...100, nil = unknown
    let detail: String?    // e.g. "resets in 2h 10m"
}

struct Amount: Identifiable {
    var id: String { label }
    let label: String
    let value: String
    let emphasized: Bool
}

struct Snapshot {
    /// Short text shown in the menu bar next to the dot.
    let headline: String
    /// 0...1, drives the dot color and blink speed.
    let ratio: Double
    /// The first two meters become the tiny vertical bars in the menu bar.
    let meters: [UsageMeter]
    let amounts: [Amount]
    let footnote: String?
    /// A monotonically growing number; when it increases the dot flashes.
    let activityKey: Double
}

struct UsageError: LocalizedError {
    let short: String
    let long: String
    /// Server asked us to slow down; seconds to wait if it said so.
    var retryAfter: TimeInterval? = nil
    var isRateLimit = false
    var errorDescription: String? { long }
}

// MARK: - JSON helpers

func number(_ any: Any?) -> Double? {
    switch any {
    case let n as NSNumber: return n.doubleValue
    case let s as String: return Double(s)
    default: return nil
    }
}

func formatMoney(_ value: Double, currency: String = "USD") -> String {
    let symbol = currency == "USD" ? "$" : currency + " "
    return symbol + String(format: "%.2f", value)
}

func parseISODate(_ any: Any?) -> Date? {
    guard let raw = any as? String else { return nil }
    let full = ISO8601DateFormatter()
    full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = full.date(from: raw) { return d }
    // Some responses carry microseconds, which older Foundation versions reject.
    let trimmed = raw.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: trimmed)
}

func formatCountdown(to date: Date) -> String {
    let seconds = Int(date.timeIntervalSinceNow)
    if seconds <= 0 { return L.now }
    let days = seconds / 86_400
    let hours = (seconds % 86_400) / 3_600
    let minutes = (seconds % 3_600) / 60
    if days > 0 { return "\(days)\(L.dayUnit) \(hours)\(L.hourUnit)" }
    if hours > 0 { return "\(hours)\(L.hourUnit) \(minutes)\(L.minuteUnit)" }
    return "\(max(1, minutes))\(L.minuteUnit)"
}
