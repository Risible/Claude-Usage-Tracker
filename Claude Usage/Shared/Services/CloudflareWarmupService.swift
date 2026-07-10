import WebKit

extension AppError {
    /// Marker embedded in technicalDetails to identify Cloudflare-challenge
    /// errors, so retry logic can distinguish "blocked by bot check" from a
    /// genuinely expired session key (both are HTTP 401/403 → E3000).
    static let cloudflareChallengeMarker = "cloudflare-challenge"

    var isCloudflareChallenge: Bool {
        (technicalDetails ?? "").contains(AppError.cloudflareChallengeMarker)
    }
}

/// Solves Cloudflare's managed JS challenge for claude.ai in an off-screen
/// WKWebView and copies the resulting clearance cookies (cf_clearance,
/// __cf_bm) into HTTPCookieStorage.shared, where ClaudeAPIService attaches
/// them to its plain URLSession requests.
///
/// claude.ai now fronts /api/* with a challenge for clients that present no
/// CF cookies at all — which is exactly the state of the manual session-key
/// paste flow, where the sign-in webview (the usual cookie source) never
/// ran. The managed challenge normally auto-solves in a hidden webview
/// within a few seconds and needs no user interaction.
final class CloudflareWarmupService: NSObject {
    static let shared = CloudflareWarmupService()

    private var webView: WKWebView?
    private var activeTask: Task<Bool, Never>?
    private var lastAttempt: Date?

    /// Minimum spacing between warm-up attempts so the periodic refresh
    /// can't spawn webviews in a loop if Cloudflare keeps challenging.
    private let attemptCooldown: TimeInterval = 300

    private static let claudeURL = URL(string: "https://claude.ai")!
    private static let cfCookieNames: Set<String> = ["cf_clearance", "__cf_bm"]

    private override init() { super.init() }

    /// Whether a warm-up is worth attempting (cooldown elapsed or never run).
    var canAttempt: Bool {
        guard let last = lastAttempt else { return true }
        return Date().timeIntervalSince(last) >= attemptCooldown
    }

    /// Loads claude.ai off-screen and waits for clearance cookies.
    /// Returns true if CF cookies were captured into HTTPCookieStorage.shared.
    /// Concurrent callers share a single attempt.
    func warmUp(timeout: TimeInterval = 20) async -> Bool {
        if let task = activeTask {
            return await task.value
        }
        lastAttempt = Date()
        let task = Task<Bool, Never> { [weak self] in
            await self?.runWarmup(timeout: timeout) ?? false
        }
        activeTask = task
        let result = await task.value
        activeTask = nil
        return result
    }

    private func runWarmup(timeout: TimeInterval) async -> Bool {
        LoggingService.shared.log("CloudflareWarmupService: starting warm-up")

        let config = WKWebViewConfiguration()
        // Default (persistent) data store: reuses any clearance the sign-in
        // webview already earned, and keeps ours for future launches.
        config.websiteDataStore = .default()

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 768), configuration: config)
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
        self.webView = webView

        webView.load(URLRequest(url: Self.claudeURL))

        let deadline = Date().addingTimeInterval(timeout)
        var sawClearance = false
        var sawAnyCFCookie = false

        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 500_000_000)

            let cookies = await allWebViewCookies(from: config.websiteDataStore.httpCookieStore)
            let cfCookies = cookies.filter {
                Self.cfCookieNames.contains($0.name) && $0.domain.contains("claude.ai")
            }
            guard !cfCookies.isEmpty else { continue }

            for cookie in cfCookies {
                HTTPCookieStorage.shared.setCookie(cookie)
            }
            sawAnyCFCookie = true
            sawClearance = cfCookies.contains { $0.name == "cf_clearance" }
            // __cf_bm alone often satisfies the challenge check; keep polling
            // briefly for cf_clearance but succeed either way.
            if sawClearance { break }
        }

        webView.stopLoading()
        self.webView = nil

        LoggingService.shared.log("CloudflareWarmupService: finished (cf_clearance: \(sawClearance), any CF cookie: \(sawAnyCFCookie))")
        return sawAnyCFCookie
    }

    private func allWebViewCookies(from store: WKHTTPCookieStore) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            store.getAllCookies { cookies in
                continuation.resume(returning: cookies)
            }
        }
    }
}
