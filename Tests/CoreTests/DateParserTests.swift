import XCTest
@testable import Core

final class DateParserTests: XCTestCase {
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    lazy var now: Date = date(2026, 8, 25, 10, 0) // a Tuesday

    func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
        cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }

    func parse(_ s: String) -> Date? { DateParser.parse(s, now: now, calendar: cal) }

    func testISOFormats() {
        XCTAssertEqual(parse("2026-08-27 14:00"), date(2026, 8, 27, 14, 0))
        XCTAssertEqual(parse("2026-08-27"), date(2026, 8, 27))
    }

    func testNaturals() {
        XCTAssertEqual(parse("today"), date(2026, 8, 25))
        XCTAssertEqual(parse("tomorrow"), date(2026, 8, 26))
        XCTAssertEqual(parse("tomorrow 9am"), date(2026, 8, 26, 9, 0))
        XCTAssertEqual(parse("friday"), date(2026, 8, 28))
        XCTAssertEqual(parse("friday 2pm"), date(2026, 8, 28, 14, 0))
        XCTAssertEqual(parse("tuesday"), date(2026, 9, 1)) // next tuesday, never today
    }

    func testTimeOnlyMeansToday() {
        XCTAssertEqual(parse("2pm"), date(2026, 8, 25, 14, 0))
        XCTAssertEqual(parse("14:30"), date(2026, 8, 25, 14, 30))
        XCTAssertEqual(parse("12am"), date(2026, 8, 25, 0, 0))
        XCTAssertEqual(parse("12pm"), date(2026, 8, 25, 12, 0))
    }

    func testOffsets() {
        XCTAssertEqual(parse("+7d"), now.addingTimeInterval(7 * 86_400))
        XCTAssertEqual(parse("+2h"), now.addingTimeInterval(2 * 3_600))
        XCTAssertEqual(parse("+30m"), now.addingTimeInterval(30 * 60))
    }

    func testYesterday() {
        XCTAssertEqual(parse("yesterday"), date(2026, 8, 24))
        XCTAssertEqual(parse("yesterday 9am"), date(2026, 8, 24, 9, 0))
    }

    func testPastOffsetsAndWeeks() {
        XCTAssertEqual(parse("-2h"), now.addingTimeInterval(-2 * 3_600))
        XCTAssertEqual(parse("-30m"), now.addingTimeInterval(-30 * 60))
        XCTAssertEqual(parse("-3d"), date(2026, 8, 22, 10, 0))
        XCTAssertEqual(parse("+1w"), date(2026, 9, 1, 10, 0))
        XCTAssertEqual(parse("-1w"), date(2026, 8, 18, 10, 0))
        XCTAssertNil(parse("2h"))       // a bare offset only means the past to parsePast
        XCTAssertNil(parse("-5x"))
        XCTAssertNil(parse("+-5d"))
    }

    func testParsePastReadsBareOffsetsAsAgo() {
        func past(_ s: String) -> Date? { DateParser.parsePast(s, now: now, calendar: cal) }
        XCTAssertEqual(past("2h"), now.addingTimeInterval(-2 * 3_600))
        XCTAssertEqual(past("30m"), now.addingTimeInterval(-30 * 60))
        XCTAssertEqual(past("3d"), date(2026, 8, 22, 10, 0))
        XCTAssertEqual(past("1w"), date(2026, 8, 18, 10, 0))
        XCTAssertEqual(past("-2h"), now.addingTimeInterval(-2 * 3_600))
        XCTAssertEqual(past(" 3D "), date(2026, 8, 22, 10, 0))
        // Everything else reads as parse does.
        XCTAssertEqual(past("2026-08-01"), date(2026, 8, 1))
        XCTAssertEqual(past("2026-08-01 14:00"), date(2026, 8, 1, 14, 0))
        XCTAssertEqual(past("yesterday"), date(2026, 8, 24))
        XCTAssertEqual(past("2pm"), date(2026, 8, 25, 14, 0))
        XCTAssertEqual(past("14:30"), date(2026, 8, 25, 14, 30))
        XCTAssertNil(past(""))
        XCTAssertNil(past("2"))
        XCTAssertNil(past("soon"))
    }

    func testPastDayOffsetIsDSTCorrect() {
        var ny = Calendar(identifier: .gregorian)
        ny.timeZone = TimeZone(identifier: "America/New_York")!
        // 2026-03-09 10:00 EDT; 3d back crosses spring-forward and stays at 10:00.
        let start = ny.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 10))!
        let expected = ny.date(from: DateComponents(year: 2026, month: 3, day: 6, hour: 10))!
        XCTAssertEqual(DateParser.parsePast("3d", now: start, calendar: ny), expected)
    }

    func testParsePastRejectsOffsetsBeyondACentury() {
        func past(_ s: String) -> Date? { DateParser.parsePast(s, now: now, calendar: cal) }
        for s in ["1e20h", "-1e20h", "+1e20d", "infd", "-infd", "+infm", "1e300w", "5300w"] {
            XCTAssertNil(past(s), s)
        }
        XCTAssertNotNil(past("5200w"))
        XCTAssertNotNil(past("36000d"))
    }

    func testRejects() {
        XCTAssertNil(parse(""))
        XCTAssertNil(parse("nonsense"))
        XCTAssertNil(parse("9"))        // bare number is ambiguous
        XCTAssertNil(parse("25pm"))
        XCTAssertNil(parse("+5x"))
    }

    func testDurations() {
        XCTAssertEqual(DurationParser.parse("1h"), 3_600)
        XCTAssertEqual(DurationParser.parse("30m"), 1_800)
        XCTAssertEqual(DurationParser.parse("1h30m"), 5_400)
        XCTAssertEqual(DurationParser.parse("2d"), 172_800)
        XCTAssertNil(DurationParser.parse("banana"))
        XCTAssertNil(DurationParser.parse("90"))
    }

    func testDayOffsetIsDSTCorrect() {
        var ny = Calendar(identifier: .gregorian)
        ny.timeZone = TimeZone(identifier: "America/New_York")!
        // 2026-03-01 10:00 EST; +7d crosses the US DST spring-forward on 2026-03-08.
        let start = ny.date(from: DateComponents(year: 2026, month: 3, day: 1, hour: 10))!
        let expected = ny.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 10))!
        XCTAssertEqual(DateParser.parse("+7d", now: start, calendar: ny), expected)
    }

    func testHugeDayOffsetDoesNotCrash() {
        XCTAssertNotNil(parse("+1e30d"))
    }
}
