import XCTest
@testable import UsageCore

final class UsageParserTests: XCTestCase {
    let sample = """
    {
      "five_hour": {"utilization": 37.0, "resets_at": "2025-11-04T04:59:59.943648+00:00"},
      "seven_day": {"utilization": 52, "resets_at": "2025-11-08T09:00:00+00:00"},
      "seven_day_oauth_apps": null,
      "seven_day_opus": {"utilization": 0.0, "resets_at": null},
      "extra_usage": {"is_enabled": false, "monthly_limit": null},
      "some_flag": true
    }
    """

    func testParsesSessionAndWeekly() throws {
        let snap = try UsageParser.parse(Data(sample.utf8))
        XCTAssertEqual(snap.session?.utilization, 37)
        XCTAssertEqual(snap.session?.remainingPercent, 63)
        XCTAssertEqual(snap.weekly?.utilization, 52)
        XCTAssertEqual(snap.weekly?.remainingFraction ?? 0, 0.48, accuracy: 1e-9)
    }

    func testOtherWindowsSkipNullAndForeignShapes() throws {
        let snap = try UsageParser.parse(Data(sample.utf8))
        XCTAssertEqual(snap.others.map(\.key), ["seven_day_opus"])
        XCTAssertNil(snap.others.first?.resetsAt)
        XCTAssertEqual(snap.allWindows.count, 3)
    }

    func testParsesMicrosecondTimestamps() throws {
        let snap = try UsageParser.parse(Data(sample.utf8))
        let expected = DateParsing.parseISO8601("2025-11-04T04:59:59Z")!.addingTimeInterval(0.943648)
        XCTAssertEqual(snap.session!.resetsAt!.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 1e-3)
        XCTAssertNotNil(DateParsing.parseISO8601("2025-11-08T09:00:00.123Z"))
        XCTAssertNil(DateParsing.parseISO8601("garbage"))
    }

    func testRemainingIsClamped() {
        XCTAssertEqual(UsageWindow(key: "x", utilization: 130, resetsAt: nil).remainingFraction, 0)
        XCTAssertEqual(UsageWindow(key: "x", utilization: -5, resetsAt: nil).remainingFraction, 1)
    }

    func testRejectsHTMLAndEmptyObjects() {
        XCTAssertThrowsError(try UsageParser.parse(Data("<html>Just a moment...</html>".utf8)))
        XCTAssertThrowsError(try UsageParser.parse(Data("{}".utf8))) { error in
            XCTAssertEqual(error as? UsageParseError, .noUsageWindows)
        }
    }
}

final class OrganizationTests: XCTestCase {
    let json = """
    [
      {"uuid": "api-org", "name": "Console", "capabilities": ["api"]},
      {"uuid": "chat-org", "name": "Personal", "capabilities": ["chat", "claude_max"]},
      {"uuid": "team-org", "name": "Team", "capabilities": ["chat", "raven"]}
    ]
    """

    func testChoosesFirstChatOrgByDefault() throws {
        let orgs = try Organization.parseList(Data(json.utf8))
        XCTAssertEqual(orgs.count, 3)
        XCTAssertEqual(Organization.choose(from: orgs, preferredID: nil)?.id, "chat-org")
    }

    func testHonoursPreferredOrg() throws {
        let orgs = try Organization.parseList(Data(json.utf8))
        XCTAssertEqual(Organization.choose(from: orgs, preferredID: "team-org")?.id, "team-org")
        XCTAssertEqual(Organization.choose(from: orgs, preferredID: "gone")?.id, "chat-org")
    }
}

final class FormattingTests: XCTestCase {
    func testDuration() {
        XCTAssertEqual(UsageFormatting.duration(30), "<1m")
        XCTAssertEqual(UsageFormatting.duration(45 * 60), "45m")
        XCTAssertEqual(UsageFormatting.duration(2 * 3600 + 13 * 60 + 59), "2h 13m")
        XCTAssertEqual(UsageFormatting.duration(3 * 3600), "3h")
        XCTAssertEqual(UsageFormatting.duration(3 * 86400 + 4 * 3600 + 120), "3d 4h")
    }

    func testResetDescription() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(UsageFormatting.resetDescription(nil, now: now), "No usage in this window yet")
        XCTAssertEqual(UsageFormatting.resetDescription(now.addingTimeInterval(-5), now: now), "Resetting now")
        XCTAssertEqual(UsageFormatting.resetDescription(now.addingTimeInterval(7980), now: now), "Resets in 2h 13m")
        let far = UsageFormatting.resetDescription(
            now.addingTimeInterval(3 * 86400 + 3600), now: now,
            locale: Locale(identifier: "en_GB"), timeZone: TimeZone(identifier: "UTC")!
        )
        XCTAssertTrue(far.hasPrefix("Resets "), far)
        XCTAssertTrue(far.hasSuffix("(in 3d 1h)"), far)
    }
}

final class UpdateCheckerTests: XCTestCase {
    func testIsNewerComparesNumericComponents() {
        XCTAssertTrue(UpdateChecker.isNewer("0.2.0", than: "0.1.0"))
        XCTAssertTrue(UpdateChecker.isNewer("v0.10.0", than: "0.9.3"))
        XCTAssertTrue(UpdateChecker.isNewer("1.0", than: "0.9.9"))
        XCTAssertTrue(UpdateChecker.isNewer("1.0.1", than: "1.0"))
        XCTAssertFalse(UpdateChecker.isNewer("0.1.0", than: "0.1.0"))
        XCTAssertFalse(UpdateChecker.isNewer("v0.1.0", than: "0.1"))
        XCTAssertFalse(UpdateChecker.isNewer("0.1.0", than: "0.2.0"))
        XCTAssertFalse(UpdateChecker.isNewer("nightly", than: "0.1.0"))
    }

    func testDevelopmentBuilds() {
        XCTAssertTrue(UpdateChecker.isDevelopmentBuild("0.0.0-dev"))
        XCTAssertTrue(UpdateChecker.isDevelopmentBuild("0.0.0-42"))
        XCTAssertFalse(UpdateChecker.isDevelopmentBuild("0.1.0"))
        XCTAssertTrue(UpdateChecker.isNewer("0.1.0", than: "0.0.0-42"))
    }

    func testParsesLatestRelease() {
        let json = """
        {"tag_name": "v0.2.0", "name": "v0.2.0", "draft": false,
         "html_url": "https://github.com/lmilcin/claude-usage-monitor/releases/tag/v0.2.0"}
        """
        let release = UpdateChecker.parseLatestRelease(Data(json.utf8))
        XCTAssertEqual(release?.version, "0.2.0")
        XCTAssertEqual(release?.pageURL.absoluteString,
                       "https://github.com/lmilcin/claude-usage-monitor/releases/tag/v0.2.0")
    }

    func testRejectsReleasesWithoutAGitHubPage() {
        let foreign = #"{"tag_name": "v9.9.9", "html_url": "https://example.com/download"}"#
        XCTAssertNil(UpdateChecker.parseLatestRelease(Data(foreign.utf8)))
        let insecure = #"{"tag_name": "v9.9.9", "html_url": "http://github.com/x/y/releases/tag/v9.9.9"}"#
        XCTAssertNil(UpdateChecker.parseLatestRelease(Data(insecure.utf8)))
        XCTAssertNil(UpdateChecker.parseLatestRelease(Data(#"{"message": "Not Found"}"#.utf8)))
        XCTAssertNil(UpdateChecker.parseLatestRelease(Data("<html>".utf8)))
    }
}
