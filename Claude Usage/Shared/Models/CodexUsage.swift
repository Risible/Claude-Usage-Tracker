import Foundation

/// Snapshot of OpenAI Codex rate-limit usage fetched from the ChatGPT backend
/// (`/backend-api/wham/usage`). In-memory only — not persisted with profiles.
///
/// Windows are classified by duration, not response position: on Plus the
/// backend sends 5h as `primary_window` and weekly as `secondary_window`,
/// but on Pro the weekly window arrives as `primary_window` with
/// `secondary_window` null. Either window may therefore be absent.
struct CodexUsage: Codable, Equatable {
    struct Window: Codable, Equatable {
        let percentage: Double
        let resetTime: Date?
        let windowSeconds: TimeInterval?
    }

    /// Short rolling window (~5h). Absent on plans that only report weekly.
    let session: Window?

    /// 7-day window.
    let weekly: Window?

    /// ChatGPT plan the account is on ("plus", "pro", "team", ...)
    let planType: String?

    let lastUpdated: Date

    /// The window the menu bar ring tracks: weekly, falling back to the
    /// session window if weekly isn't reported.
    var menuBarWindow: Window? {
        weekly ?? session
    }

    static let empty = CodexUsage(
        session: nil,
        weekly: nil,
        planType: nil,
        lastUpdated: Date()
    )
}
