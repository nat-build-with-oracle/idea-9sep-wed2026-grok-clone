import Foundation
import XCTest

@testable import WorkspaceCore

final class RoutineScheduleTests: XCTestCase {
  private func date(_ value: String) -> Date {
    ISO8601DateFormatter().date(from: value)!
  }

  func testIntervalUsesElapsedTimeAcrossSpringForward() throws {
    let next = try RoutineSchedule.next(
      after: date("2026-03-08T06:55:00Z"), trigger: .interval(minutes: 10),
      timezoneID: "America/New_York")
    XCTAssertEqual(next, date("2026-03-08T07:05:00Z"))
  }

  func testSpringForwardGapRunsAtNextValidTimeNotPreservingMinutes() throws {
    let next = try RoutineSchedule.next(
      after: date("2026-03-08T05:00:00Z"), trigger: .daily(hour: 2, minute: 30),
      timezoneID: "America/New_York")
    XCTAssertEqual(next, date("2026-03-08T07:00:00Z"))
    XCTAssertEqual(
      try RoutineSchedule.next(
        after: next, trigger: .daily(hour: 2, minute: 30),
        timezoneID: "America/New_York"), date("2026-03-09T06:30:00Z"))
  }

  func testFallBackUsesFirstOccurrenceAndNeverSecondCopy() throws {
    let trigger = Routine.Trigger.daily(hour: 1, minute: 30)
    let first = try RoutineSchedule.next(
      after: date("2026-11-01T04:00:00Z"), trigger: trigger, timezoneID: "America/New_York")
    XCTAssertEqual(first, date("2026-11-01T05:30:00Z"))
    for instant in [first, date("2026-11-01T06:00:00Z"), date("2026-11-01T06:30:00Z")] {
      XCTAssertEqual(
        try RoutineSchedule.next(after: instant, trigger: trigger, timezoneID: "America/New_York"),
        date("2026-11-02T06:30:00Z"))
    }
    let id = UUID()
    XCTAssertEqual(
      try RoutineSchedule.occurrenceID(
        scheduleID: id, at: first, trigger: trigger,
        timezoneID: "America/New_York"),
      try RoutineSchedule.occurrenceID(
        scheduleID: id, at: date("2026-11-01T06:30:00Z"),
        trigger: trigger, timezoneID: "America/New_York"))
  }

  func testNonHourDSTGap() throws {
    let next = try RoutineSchedule.next(
      after: date("2026-10-03T13:30:00Z"), trigger: .daily(hour: 2, minute: 15),
      timezoneID: "Australia/Lord_Howe")
    XCTAssertEqual(next, date("2026-10-03T15:30:00Z"))
  }

  func testNamedTimeZoneAndGregorianDateIdentity() throws {
    let id = UUID()
    let next = try RoutineSchedule.next(
      after: date("2026-09-09T18:00:00Z"), trigger: .daily(hour: 9, minute: 0),
      timezoneID: "Asia/Bangkok")
    XCTAssertEqual(next, date("2026-09-10T02:00:00Z"))
    XCTAssertEqual(
      try RoutineSchedule.occurrenceID(
        scheduleID: id, at: next,
        trigger: .daily(hour: 9, minute: 0), timezoneID: "Asia/Bangkok"),
      id.uuidString + ":day-2026-9-10")
  }

  func testWeekAsleepCoalescesIntervalsWithoutCatchUpBurst() throws {
    let first = date("2026-09-01T00:00:00Z")
    let now = date("2026-09-08T00:02:00Z")
    let due = try XCTUnwrap(
      RoutineSchedule.due(
        from: first, through: now, trigger: .interval(minutes: 5), timezoneID: "UTC"))
    XCTAssertEqual(due.latest, date("2026-09-08T00:00:00Z"))
    XCTAssertEqual(due.next, date("2026-09-08T00:05:00Z"))
    XCTAssertEqual(due.skippedCount, 2016)
    XCTAssertEqual(due.firstSkippedAt, first)
    XCTAssertEqual(due.lastSkippedAt, date("2026-09-07T23:55:00Z"))
    XCTAssertNil(
      try RoutineSchedule.due(
        from: due.next, through: now, trigger: .interval(minutes: 5), timezoneID: "UTC"))
  }

  func testDailyCatchUpAcrossDSTCountsLocalDaysAndSelectsLatest() throws {
    let due = try XCTUnwrap(
      RoutineSchedule.due(
        from: date("2026-03-06T07:30:00Z"), through: date("2026-03-09T06:00:00Z"),
        trigger: .daily(hour: 2, minute: 30), timezoneID: "America/New_York"))
    XCTAssertEqual(due.latest, date("2026-03-08T07:00:00Z"))
    XCTAssertEqual(due.next, date("2026-03-09T06:30:00Z"))
    XCTAssertEqual(due.skippedCount, 2)
    XCTAssertEqual(due.lastSkippedAt, date("2026-03-07T07:30:00Z"))
  }

  func testFallBackCatchUpDoesNotTreatRepeatedHourAsAnotherOccurrence() throws {
    let due = try XCTUnwrap(
      RoutineSchedule.due(
        from: date("2026-11-01T05:30:00Z"), through: date("2026-11-01T06:45:00Z"),
        trigger: .daily(hour: 1, minute: 30), timezoneID: "America/New_York"))
    XCTAssertEqual(due.skippedCount, 0)
    XCTAssertNil(due.firstSkippedAt)
    XCTAssertNil(due.lastSkippedAt)
    XCTAssertEqual(due.latest, date("2026-11-01T05:30:00Z"))
    XCTAssertEqual(due.next, date("2026-11-02T06:30:00Z"))
    XCTAssertThrowsError(
      try RoutineSchedule.due(
        from: date("2026-11-01T06:30:00Z"), through: date("2026-11-01T06:45:00Z"),
        trigger: .daily(hour: 1, minute: 30), timezoneID: "America/New_York"))
  }

  func testExactBoundaryAndClockMovingBackwards() throws {
    let first = date("2026-09-01T00:00:00Z")
    XCTAssertNil(
      try RoutineSchedule.due(
        from: first, through: first.addingTimeInterval(-1), trigger: .interval(minutes: 5),
        timezoneID: "UTC"))
    let due = try XCTUnwrap(
      RoutineSchedule.due(
        from: first, through: first, trigger: .interval(minutes: 5), timezoneID: "UTC"))
    XCTAssertEqual(due.latest, first)
    XCTAssertEqual(due.skippedCount, 0)
    XCTAssertEqual(due.next, first.addingTimeInterval(300))
  }

  func testFractionalIntervalIdentityIsStableWithoutRoundingCollisions() throws {
    let first = Date(timeIntervalSinceReferenceDate: 810_000_000.12345)
    let id = UUID()
    let trigger = Routine.Trigger.interval(minutes: 5)
    let key = try RoutineSchedule.occurrenceID(
      scheduleID: id, at: first, trigger: trigger, timezoneID: "UTC")
    let encoded = try JSONEncoder().encode(first)
    let decoded = try JSONDecoder().decode(Date.self, from: encoded)
    XCTAssertEqual(
      key,
      try RoutineSchedule.occurrenceID(
        scheduleID: id, at: decoded, trigger: trigger, timezoneID: "UTC"))
    XCTAssertNotEqual(
      key,
      try RoutineSchedule.occurrenceID(
        scheduleID: id, at: first.addingTimeInterval(0.001), trigger: trigger, timezoneID: "UTC"))
  }

  func testInvalidInputsFailWithoutSpinningOrOverflow() {
    for trigger in [
      Routine.Trigger.interval(minutes: 4), .interval(minutes: Int.max),
      .daily(hour: 24, minute: 0), .daily(hour: 0, minute: -1),
    ] {
      XCTAssertThrowsError(
        try RoutineSchedule.next(after: Date(), trigger: trigger, timezoneID: "UTC"))
    }
    XCTAssertThrowsError(
      try RoutineSchedule.next(
        after: Date(), trigger: .interval(minutes: 5), timezoneID: "not/a/zone"))
    for date in [
      Date(timeIntervalSinceReferenceDate: .nan),
      Date(timeIntervalSinceReferenceDate: .infinity), Date.distantFuture,
    ] {
      XCTAssertThrowsError(
        try RoutineSchedule.next(
          after: date, trigger: .interval(minutes: 5), timezoneID: "UTC"))
    }
  }

  func testSkippedCivilDateDoesNotInventAnOccurrence() throws {
    let first = date("2011-12-29T19:00:00Z")
    let due = try XCTUnwrap(
      RoutineSchedule.due(
        from: first, through: date("2011-12-30T19:00:00Z"), trigger: .daily(hour: 9, minute: 0),
        timezoneID: "Pacific/Apia"))
    // Samoa skipped local December 30 entirely. Only the existing December 29 occurrence is skipped.
    XCTAssertEqual(due.skippedCount, 1)
    XCTAssertEqual(due.lastSkippedAt, first)
    XCTAssertEqual(due.latest, date("2011-12-30T19:00:00Z"))
    XCTAssertEqual(due.next, date("2011-12-31T19:00:00Z"))
  }

  func testMidnightGapUsesFirstValidInstantOfThatLocalDay() throws {
    let next = try RoutineSchedule.next(
      after: date("2019-09-07T04:00:00Z"), trigger: .daily(hour: 0, minute: 0),
      timezoneID: "America/Santiago")
    XCTAssertEqual(next, date("2019-09-08T04:00:00Z"))
    XCTAssertEqual(
      try RoutineSchedule.next(
        after: next, trigger: .daily(hour: 0, minute: 0), timezoneID: "America/Santiago"),
      date("2019-09-09T03:00:00Z"))
  }

  func testSubMinuteHistoricalOffsetRoundTripsExistingAndMissingTime() throws {
    let first = try RoutineSchedule.next(
      after: date("1972-01-06T00:00:00Z"), trigger: .daily(hour: 0, minute: 15),
      timezoneID: "Africa/Monrovia")
    XCTAssertEqual(first, date("1972-01-06T00:59:30Z"))
    let next = try RoutineSchedule.next(
      after: first, trigger: .daily(hour: 0, minute: 15), timezoneID: "Africa/Monrovia")
    XCTAssertEqual(next, date("1972-01-07T00:44:30Z"))
  }

  func testCenturiesOfIntervalsUseConstantTimeArithmetic() throws {
    let due = try XCTUnwrap(
      RoutineSchedule.due(
        from: date("1800-01-01T00:00:00Z"), through: date("2200-01-01T00:02:00Z"),
        trigger: .interval(minutes: 5), timezoneID: "UTC"))
    XCTAssertEqual(due.skippedCount, 42_075_936)
    XCTAssertEqual(due.latest, date("2200-01-01T00:00:00Z"))
    XCTAssertEqual(due.next, date("2200-01-01T00:05:00Z"))
    let first = Date(timeIntervalSinceReferenceDate: -1_000_000_000.25)
    let negative = try XCTUnwrap(
      RoutineSchedule.due(
        from: first, through: first.addingTimeInterval(300 * 12345 + 299.5),
        trigger: .interval(minutes: 5), timezoneID: "UTC"))
    XCTAssertEqual(negative.skippedCount, 12345)
    XCTAssertEqual(negative.latest, first.addingTimeInterval(3_703_500))
  }
}
