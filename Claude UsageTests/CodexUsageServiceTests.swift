import XCTest
@testable import Claude_Usage

final class CodexUsageServiceTests: XCTestCase {

    /// Plus-plan response shape captured live from /backend-api/wham/usage
    /// (July 2026): 5h window primary, weekly window secondary.
    private let plusResponse = """
    {
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
      }
    }
    """.data(using: .utf8)!

    /// Pro-plan response shape captured live (July 2026): the weekly window
    /// arrives as primary_window and secondary_window is null. Positional
    /// parsing reported weekly = 0 here — classify by duration instead.
    private let proResponse = """
    {
      "plan_type": "pro",
      "rate_limit": {
        "allowed": true,
        "limit_reached": false,
        "primary_window": {
          "used_percent": 31,
          "limit_window_seconds": 604800,
          "reset_after_seconds": 507926,
          "reset_at": 1784390454
        },
        "secondary_window": null
      }
    }
    """.data(using: .utf8)!

    func testParsesPlusShapeIntoSessionAndWeekly() throws {
        let usage = try CodexUsageService.parseUsage(from: plusResponse)

        let session = try XCTUnwrap(usage.session)
        XCTAssertEqual(session.percentage, 1)
        XCTAssertEqual(session.windowSeconds, 18000)
        XCTAssertEqual(session.resetTime, Date(timeIntervalSince1970: 1_783_708_767))

        let weekly = try XCTUnwrap(usage.weekly)
        XCTAssertEqual(weekly.percentage, 9)
        XCTAssertEqual(weekly.windowSeconds, 604_800)
        XCTAssertEqual(weekly.resetTime, Date(timeIntervalSince1970: 1_784_241_708))

        XCTAssertEqual(usage.planType, "plus")
        XCTAssertEqual(usage.menuBarWindow, usage.weekly)
    }

    func testParsesProShapeWeeklyFromPrimarySlot() throws {
        let usage = try CodexUsageService.parseUsage(from: proResponse)

        XCTAssertNil(usage.session, "Pro reports no short window — session must be absent, not 0")

        let weekly = try XCTUnwrap(usage.weekly)
        XCTAssertEqual(weekly.percentage, 31)
        XCTAssertEqual(weekly.windowSeconds, 604_800)
        XCTAssertEqual(weekly.resetTime, Date(timeIntervalSince1970: 1_784_390_454))

        XCTAssertEqual(usage.planType, "pro")
        XCTAssertEqual(usage.menuBarWindow, usage.weekly)
    }

    func testMissingDurationFallsBackToPositionalClassification() throws {
        let json = """
        {
          "rate_limit": {
            "primary_window": { "used_percent": 42.5, "reset_after_seconds": 3600 },
            "secondary_window": { "used_percent": 7, "reset_after_seconds": 500000 }
          }
        }
        """.data(using: .utf8)!

        let before = Date().addingTimeInterval(3600 - 5)
        let usage = try CodexUsageService.parseUsage(from: json)
        let after = Date().addingTimeInterval(3600 + 5)

        let session = try XCTUnwrap(usage.session)
        XCTAssertEqual(session.percentage, 42.5)
        let reset = try XCTUnwrap(session.resetTime)
        XCTAssertTrue(reset >= before && reset <= after)

        XCTAssertEqual(usage.weekly?.percentage, 7)
    }

    func testSessionOnlyResponseFallsBackForMenuBar() throws {
        let json = """
        {
          "rate_limit": {
            "primary_window": { "used_percent": 12, "limit_window_seconds": 18000 }
          }
        }
        """.data(using: .utf8)!

        let usage = try CodexUsageService.parseUsage(from: json)
        XCTAssertNil(usage.weekly)
        XCTAssertEqual(usage.menuBarWindow, usage.session)
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
