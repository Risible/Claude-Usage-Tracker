import XCTest
@testable import Claude_Usage

final class CodexUsageServiceTests: XCTestCase {

    /// Response shape captured live from /backend-api/wham/usage (July 2026)
    private let liveResponse = """
    {
      "user_id": "user-x",
      "account_id": "user-x",
      "email": "user@example.com",
      "plan_type": "plus",
      "rate_limit": {
        "allowed": true,
        "limit_reached": false,
        "primary_window": {
          "used_percent": 1,
          "limit_window_seconds": 18000,
          "reset_after_seconds": 18000,
          "reset_at": 1783708767
        },
        "secondary_window": {
          "used_percent": 9,
          "limit_window_seconds": 604800,
          "reset_after_seconds": 550941,
          "reset_at": 1784241708
        }
      },
      "code_review_rate_limit": null,
      "additional_rate_limits": null,
      "credits": {
        "has_credits": false,
        "unlimited": false,
        "balance": "0"
      }
    }
    """.data(using: .utf8)!

    func testParsesLiveResponseShape() throws {
        let usage = try CodexUsageService.parseUsage(from: liveResponse)

        XCTAssertEqual(usage.primaryPercentage, 1)
        XCTAssertEqual(usage.primaryWindowSeconds, 18000)
        XCTAssertEqual(usage.primaryResetTime, Date(timeIntervalSince1970: 1_783_708_767))

        XCTAssertEqual(usage.weeklyPercentage, 9)
        XCTAssertEqual(usage.weeklyWindowSeconds, 604_800)
        XCTAssertEqual(usage.weeklyResetTime, Date(timeIntervalSince1970: 1_784_241_708))

        XCTAssertEqual(usage.planType, "plus")
    }

    func testFallsBackToResetAfterSecondsWhenResetAtMissing() throws {
        let json = """
        {
          "plan_type": "pro",
          "rate_limit": {
            "primary_window": { "used_percent": 42.5, "reset_after_seconds": 3600 }
          }
        }
        """.data(using: .utf8)!

        let before = Date().addingTimeInterval(3600 - 5)
        let usage = try CodexUsageService.parseUsage(from: json)
        let after = Date().addingTimeInterval(3600 + 5)

        XCTAssertEqual(usage.primaryPercentage, 42.5)
        let reset = try XCTUnwrap(usage.primaryResetTime)
        XCTAssertTrue(reset >= before && reset <= after)

        // Missing secondary window degrades to zero, not a throw
        XCTAssertEqual(usage.weeklyPercentage, 0)
        XCTAssertNil(usage.weeklyResetTime)
    }

    func testMissingRateLimitThrowsParseError() {
        let json = #"{"plan_type": "plus"}"#.data(using: .utf8)!
        XCTAssertThrowsError(try CodexUsageService.parseUsage(from: json)) { error in
            XCTAssertEqual(error as? CodexUsageError, .parseError)
        }
    }

    func testGarbageDataThrowsParseError() {
        let junk = "not json".data(using: .utf8)!
        XCTAssertThrowsError(try CodexUsageService.parseUsage(from: junk))
    }
}
