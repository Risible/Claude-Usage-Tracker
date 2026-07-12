import Foundation

enum CodexUsageError: LocalizedError, Equatable {
    /// ~/.codex/auth.json doesn't exist — Codex CLI not installed or never signed in
    case notInstalled
    /// auth.json exists but has no usable access token
    case invalidCredentials
    /// Backend rejected the token (401/403) — user needs to run `codex` to refresh
    case authExpired
    case networkError(String)
    case parseError

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "codex.error.not_installed".localized
        case .invalidCredentials:
            return "codex.error.invalid_credentials".localized
        case .authExpired:
            return "codex.error.auth_expired".localized
        case .networkError(let detail):
            return "codex.error.network".localized(with: detail)
        case .parseError:
            return "codex.error.parse".localized
        }
    }
}

/// Fetches Codex rate-limit usage from the ChatGPT backend using the OAuth
/// token the Codex CLI keeps in ~/.codex/auth.json. Read-only: never writes
/// or refreshes the CLI's credentials, so it can't disturb `codex` itself.
final class CodexUsageService {
    static let shared = CodexUsageService()

    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    private let session: URLSession

    /// Cached auth-file presence so menu bar gating stays off the disk
    /// (mirrors ClaudeCodeSyncService.hasUsableSystemCredentials).
    private var installedCache: (value: Bool, timestamp: Date)?
    private let installedCacheTTL: TimeInterval = 15

    private init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)
    }

    // MARK: - Availability

    /// Whether the Codex CLI auth file exists. Cheap (cached) — safe to call
    /// from UI paths.
    func isCodexInstalled() -> Bool {
        if let cache = installedCache, Date().timeIntervalSince(cache.timestamp) < installedCacheTTL {
            return cache.value
        }
        let exists = FileManager.default.fileExists(atPath: Constants.CodexPaths.authFile.path)
        installedCache = (exists, Date())
        return exists
    }

    func invalidateInstalledCache() {
        installedCache = nil
    }

    // MARK: - Fetch

    func fetchUsage() async throws -> CodexUsage {
        guard FileManager.default.fileExists(atPath: Constants.CodexPaths.authFile.path) else {
            throw CodexUsageError.notInstalled
        }
        // Re-read the file on every fetch: the Codex CLI rotates the token in
        // place, and re-reading picks up refreshed credentials for free.
        guard let auth = readAuthTokens() else {
            throw CodexUsageError.invalidCredentials
        }

        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(auth.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let accountId = auth.accountId, !accountId.isEmpty {
            request.setValue(accountId, forHTTPHeaderField: "chatgpt-account-id")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw CodexUsageError.networkError(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw CodexUsageError.networkError("No HTTP response")
        }
        switch http.statusCode {
        case 200:
            break
        case 401, 403:
            LoggingService.shared.logWarning("CodexUsageService: token rejected (HTTP \(http.statusCode))")
            throw CodexUsageError.authExpired
        default:
            throw CodexUsageError.networkError("HTTP \(http.statusCode)")
        }

        return try Self.parseUsage(from: data)
    }

    // MARK: - Auth file

    private struct AuthTokens {
        let accessToken: String
        let accountId: String?
    }

    private func readAuthTokens() -> AuthTokens? {
        let url = Constants.CodexPaths.authFile
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            LoggingService.shared.logWarning("CodexUsageService: could not read/parse \(url.path)")
            return nil
        }
        guard let tokens = json["tokens"] as? [String: Any],
              let accessToken = tokens["access_token"] as? String,
              !accessToken.isEmpty else {
            return nil
        }
        return AuthTokens(accessToken: accessToken, accountId: tokens["account_id"] as? String)
    }

    // MARK: - Parsing

    /// Parses the wham/usage response. Static + internal for unit testing.
    ///
    /// Windows are classified by `limit_window_seconds`, not response
    /// position: Plus sends 5h/weekly as primary/secondary, but Pro sends
    /// the weekly window as `primary_window` with `secondary_window` null.
    static func parseUsage(from data: Data) throws -> CodexUsage {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rateLimit = json["rate_limit"] as? [String: Any] else {
            throw CodexUsageError.parseError
        }

        func window(_ key: String) -> CodexUsage.Window? {
            guard let w = rateLimit[key] as? [String: Any] else { return nil }
            let percent = (w["used_percent"] as? NSNumber)?.doubleValue ?? 0
            var reset: Date?
            if let resetAt = (w["reset_at"] as? NSNumber)?.doubleValue, resetAt > 0 {
                reset = Date(timeIntervalSince1970: resetAt)
            } else if let after = (w["reset_after_seconds"] as? NSNumber)?.doubleValue, after > 0 {
                reset = Date().addingTimeInterval(after)
            }
            let duration = (w["limit_window_seconds"] as? NSNumber)?.doubleValue
            return CodexUsage.Window(percentage: percent, resetTime: reset, windowSeconds: duration)
        }

        var session: CodexUsage.Window?
        var weekly: CodexUsage.Window?

        for (key, positionalIsWeekly) in [("primary_window", false), ("secondary_window", true)] {
            guard let w = window(key) else { continue }
            let isWeekly: Bool
            if let seconds = w.windowSeconds {
                // ≥2 days → weekly bucket; anything shorter → session bucket
                isWeekly = seconds >= 2 * 86400
            } else {
                // No duration reported: fall back to positional convention
                isWeekly = positionalIsWeekly
            }
            if isWeekly {
                if weekly == nil { weekly = w }
            } else {
                if session == nil { session = w }
            }
        }

        return CodexUsage(
            session: session,
            weekly: weekly,
            planType: json["plan_type"] as? String,
            lastUpdated: Date()
        )
    }
}
