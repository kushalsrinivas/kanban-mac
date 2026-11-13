import XCTest

/// Regressions found by the second-pass audit. These guard against silent data loss
/// rather than exercising every parser branch.
@MainActor
final class DateRegressionTests: XCTestCase {

    func testYearlessDatesUseTheCurrentYear() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 6, day: 1, hour: 9))!

        for input in ["18 sep", "sep 18", "18/09"] {
            guard let date = DateInput.parse(input, now: now, calendar: calendar) else {
                return XCTFail("could not parse \(input)")
            }
            XCTAssertEqual(calendar.component(.year, from: date), 2026, input)
            XCTAssertEqual(calendar.component(.month, from: date), 9, input)
            XCTAssertEqual(calendar.component(.day, from: date), 18, input)
        }

        // A date already past this year rolls forward to the next.
        let january = DateInput.parse("18 jan", now: now, calendar: calendar)
        XCTAssertEqual(january.map { calendar.component(.year, from: $0) }, 2027)
    }

    func testTwoDigitYearIsHonoured() {
        let parsed = DateInput.parse("18 SEP 27")
        XCTAssertEqual(parsed.map { Calendar.current.component(.year, from: $0) }, 2027)
    }

    func testShortLabelsRoundTripThroughTheParser() {
        let now = Date.now
        XCTAssertNotNil(DateInput.parse("tmrw", now: now), "TMRW is shown in the due field")
        XCTAssertNotNil(DateInput.parse(DateInput.shortLabel(now.addingTimeInterval(86_400 * 30), now: now)))
    }
}
