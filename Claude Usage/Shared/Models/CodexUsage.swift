import Foundation

/// Snapshot of OpenAI Codex rate-limit usage fetched from the ChatGPT backend
/// (`/backend-api/wham/usage`). In-memory only — not persisted with profiles.
struct CodexUsage: Codable, Equatable {
    /// 5-hour rolling window ("primary_window")
    let primaryPercentage: Double
    let primaryResetTime: Date?
    let primaryWindowSeconds: TimeInterval?

    /// Weekly window ("secondary_window")
    let weeklyPercentage: Double
    let weeklyResetTime: Date?
    let weeklyWindowSeconds: TimeInterval?

    /// ChatGPT plan the account is on ("plus", "pro", "team", ...)
    let planType: String?

    let lastUpdated: Date

    static let empty = CodexUsage(
        primaryPercentage: 0,
        primaryResetTime: nil,
        primaryWindowSeconds: nil,
        weeklyPercentage: 0,
        weeklyResetTime: nil,
        weeklyWindowSeconds: nil,
        planType: nil,
        lastUpdated: Date()
    )
}
