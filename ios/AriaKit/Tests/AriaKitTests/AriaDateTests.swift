import XCTest
@testable import AriaKit

final class AriaDateTests: XCTestCase {
    func testParsesSupabaseTimestampsWithAnyFractionPrecision() {
        let expected = Date(timeIntervalSince1970: 1_790_492_308.594913)
        let micro = AriaDate.parseTimestamp("2026-09-27T06:58:28.594913+00:00")!
        XCTAssertEqual(micro.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 0.000001)
        let nano = AriaDate.parseTimestamp("2026-09-27T06:58:28.547859337Z")!
        XCTAssertEqual(nano.timeIntervalSince1970, 1_790_492_308.547859337, accuracy: 0.000001)
        let none = AriaDate.parseTimestamp("2026-10-02T21:00:00+00:00")!
        XCTAssertEqual(none.timeIntervalSince1970, 1_790_974_800)
    }

    func testParsesOffsetsAndSeparators() {
        let reference = date("2026-10-02T21:00:00Z")
        XCTAssertEqual(AriaDate.parseTimestamp("2026-10-02T17:00:00-04:00"), reference)
        XCTAssertEqual(AriaDate.parseTimestamp("2026-10-02T17:00:00-0400"), reference)
        XCTAssertEqual(AriaDate.parseTimestamp("2026-10-02T17:00-04"), reference)
        XCTAssertEqual(AriaDate.parseTimestamp("2026-10-02 21:00:00Z"), reference)
        XCTAssertEqual(AriaDate.parseTimestamp("2026-10-03T06:30:00+09:30"), reference)
        XCTAssertEqual(AriaDate.parseTimestamp("  2026-10-02t21:00:00z "), reference)
    }

    func testValuesWithoutOffsetUseTheDefaultTimeZoneIncludingDST() {
        // 17:00 in New York is UTC-4 in October (EDT) and UTC-5 in December (EST).
        XCTAssertEqual(AriaDate.parseTimestamp("2026-10-02T17:00:00", defaultTimeZone: newYork), date("2026-10-02T21:00:00Z"))
        XCTAssertEqual(AriaDate.parseTimestamp("2026-12-02T17:00", defaultTimeZone: newYork), date("2026-12-02T22:00:00Z"))
        XCTAssertEqual(AriaDate.parseTimestamp("2026-10-02", defaultTimeZone: newYork), date("2026-10-02T04:00:00Z"))
    }

    func testRejectsInvalidInput() {
        for text in ["", "tomorrow", "2026-02-30T10:00:00Z", "2026-13-01", "2026-10-02T25:00:00Z", "2026-10-02T10:61Z",
                     "2026-10-02T10:00:00+2500", "2026-10-02T10:00:00.Z", "2026-10-02T10:00:00Zjunk", "26-10-02"] {
            XCTAssertNil(AriaDate.parseTimestamp(text), "should reject \(text)")
        }
        XCTAssertNotNil(AriaDate.parseTimestamp("2028-02-29T10:00:00Z"), "leap day")
    }

    func testFormatUTCWithMilliseconds() {
        XCTAssertEqual(AriaDate.formatUTC(Date(timeIntervalSince1970: 1_790_492_308.594913)), "2026-09-27T06:58:28.595Z")
        XCTAssertEqual(AriaDate.formatUTC(Date(timeIntervalSince1970: 0)), "1970-01-01T00:00:00.000Z")
        XCTAssertEqual(AriaDate.formatUTC(Date(timeIntervalSince1970: -1.5)), "1969-12-31T23:59:58.500Z")
    }

    func testFormatLocalIncludesOffset() {
        XCTAssertEqual(AriaDate.formatLocal(date("2026-10-02T21:00:00Z"), timeZone: newYork), "2026-10-02T17:00:00-04:00")
        XCTAssertEqual(AriaDate.formatLocal(date("2026-12-02T22:00:00Z"), timeZone: newYork), "2026-12-02T17:00:00-05:00")
        XCTAssertEqual(AriaDate.formatLocal(date("2026-10-02T21:00:00Z"), timeZone: utc), "2026-10-02T21:00:00+00:00")
        XCTAssertEqual(AriaDate.formatLocal(date("2026-10-02T21:00:00Z"), timeZone: TimeZone(identifier: "Asia/Kolkata")!),
                       "2026-10-03T02:30:00+05:30")
    }

    func testRoundTrip() {
        for text in ["2026-09-27T06:58:28.595Z", "2000-02-29T00:00:00.000Z", "2099-12-31T23:59:59.999Z"] {
            XCTAssertEqual(AriaDate.formatUTC(AriaDate.parseTimestamp(text)!), text)
        }
    }

    func testReadableFormat() {
        XCTAssertEqual(AriaDate.formatReadable(date("2026-09-27T13:41:00Z"), timeZone: newYork), "Sunday, 27 September 2026 09:41")
    }

    func testDayKey() {
        let day = DayKey("2026-10-02")!
        XCTAssertEqual(day.string, "2026-10-02")
        XCTAssertEqual(DayKey("2026-10-02T17:00:00-04:00"), day)
        XCTAssertNil(DayKey("2026-02-30"))
        XCTAssertNil(DayKey("2026-10-02X"))
        XCTAssertNil(DayKey("October 2"))
        XCTAssertEqual(day.adding(days: 30).string, "2026-11-01")
        XCTAssertEqual(DayKey("2026-12-31")!.adding(days: 1).string, "2027-01-01")
        XCTAssertEqual(DayKey("2028-03-01")!.adding(days: -1).string, "2028-02-29")
        XCTAssertLessThan(day, day.adding(days: 1))
        XCTAssertEqual(day.utcMidnight, date("2026-10-02T00:00:00Z"))
        XCTAssertEqual(day.startDate(in: calendar(newYork)), date("2026-10-02T04:00:00Z"))
        XCTAssertEqual(day.interval(in: calendar(newYork)).duration, 86_400)
        // 1 November 2026 is the DST change in New York: a 25-hour day.
        XCTAssertEqual(DayKey("2026-11-01")!.interval(in: calendar(newYork)).duration, 90_000)
        XCTAssertEqual(DayKey(date("2026-10-03T01:00:00Z"), calendar: calendar(newYork)).string, "2026-10-02")
        XCTAssertEqual(DayKey(utc: date("2026-10-03T01:00:00Z")).string, "2026-10-03")
        XCTAssertEqual(DayKey(utc: date("1969-12-31T23:00:00Z")).string, "1969-12-31")
    }

    func testDayKeyCoding() throws {
        let data = try JSONEncoder().encode(["date": DayKey("2026-10-02")!])
        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"date":"2026-10-02"}"#)
        XCTAssertEqual(try JSONDecoder().decode([String: DayKey].self, from: data)["date"], DayKey("2026-10-02"))
        XCTAssertThrowsError(try JSONDecoder().decode([String: DayKey].self, from: Data(#"{"date":"nope"}"#.utf8)))
    }
}
