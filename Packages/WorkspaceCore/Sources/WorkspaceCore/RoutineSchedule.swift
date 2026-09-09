import Foundation

/// One catch-up candidate plus an aggregate of older missed occurrences. No loop per missed run.
public struct RoutineDueWindow: Sendable, Equatable {
  public let latest: Date
  public let next: Date
  public let skippedCount: Int
  public let firstSkippedAt: Date?
  public let lastSkippedAt: Date?
}

/// Pure calendar arithmetic. Callers supply time; this type never starts tasks or reads a clock.
public enum RoutineSchedule {
  public static func next(after date: Date, trigger: Routine.Trigger, timezoneID: String) throws
    -> Date
  {
    let calendar = try validatedCalendar(trigger: trigger, timezoneID: timezoneID, dates: [date])
    switch trigger {
    case .interval(let minutes):
      let next = date.addingTimeInterval(Double(minutes) * 60)
      try validate(next)
      return next
    case .daily(let hour, let minute):
      let today = calendar.startOfDay(for: date)
      let candidate = try dailyOccurrence(on: today, hour: hour, minute: minute, calendar: calendar)
      if candidate > date { return candidate }
      guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else {
        throw WorkspaceError.invalidRoutine
      }
      return try dailyOccurrence(on: tomorrow, hour: hour, minute: minute, calendar: calendar)
    }
  }

  public static func due(
    from first: Date, through now: Date, trigger: Routine.Trigger, timezoneID: String
  ) throws -> RoutineDueWindow? {
    let calendar = try validatedCalendar(
      trigger: trigger, timezoneID: timezoneID, dates: [first, now])
    guard first <= now else { return nil }
    let latest: Date
    let next: Date
    let skippedCount: Int
    let lastSkippedAt: Date?
    switch trigger {
    case .interval(let minutes):
      let seconds = Double(minutes) * 60
      let count = floor(now.timeIntervalSince(first) / seconds)
      guard count >= 0, count < Double(Int.max) else { throw WorkspaceError.invalidRoutine }
      skippedCount = Int(count)
      latest = first.addingTimeInterval(count * seconds)
      next = latest.addingTimeInterval(seconds)
      lastSkippedAt = skippedCount > 0 ? latest.addingTimeInterval(-seconds) : nil
    case .daily(let hour, let minute):
      let firstDay = calendar.startOfDay(for: first)
      // A persisted daily occurrence must be the first matching local time, not the second copy
      // during fall-back or an arbitrary instant supplied by a caller.
      guard
        first
          == (try dailyOccurrence(
            on: firstDay, hour: hour, minute: minute, calendar: calendar))
      else { throw WorkspaceError.invalidRoutine }
      var day = calendar.startOfDay(for: now)
      var candidate = try dailyOccurrence(on: day, hour: hour, minute: minute, calendar: calendar)
      if candidate > now {
        guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else {
          throw WorkspaceError.invalidRoutine
        }
        day = previous
        candidate = try dailyOccurrence(on: day, hour: hour, minute: minute, calendar: calendar)
      }
      guard candidate >= first,
        let count = calendar.dateComponents([.day], from: firstDay, to: day).day, count >= 0
      else { throw WorkspaceError.invalidRoutine }
      latest = candidate
      skippedCount = count
      next = try self.next(after: latest, trigger: trigger, timezoneID: timezoneID)
      if count > 0 {
        guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else {
          throw WorkspaceError.invalidRoutine
        }
        lastSkippedAt = try dailyOccurrence(
          on: previous, hour: hour, minute: minute, calendar: calendar)
      } else {
        lastSkippedAt = nil
      }
    }
    try validate(next)
    guard latest <= now, next > now else { throw WorkspaceError.invalidRoutine }
    return RoutineDueWindow(
      latest: latest, next: next, skippedCount: skippedCount,
      firstSkippedAt: skippedCount > 0 ? first : nil, lastSkippedAt: lastSkippedAt)
  }

  public static func occurrenceID(
    scheduleID: UUID, at date: Date, trigger: Routine.Trigger, timezoneID: String
  ) throws -> String {
    let calendar = try validatedCalendar(trigger: trigger, timezoneID: timezoneID, dates: [date])
    let suffix: String
    switch trigger {
    case .interval:
      suffix = "instant-" + String(date.timeIntervalSinceReferenceDate.bitPattern, radix: 16)
    case .daily:
      let components = calendar.dateComponents([.year, .month, .day], from: date)
      guard let year = components.year, let month = components.month, let day = components.day
      else {
        throw WorkspaceError.invalidRoutine
      }
      suffix = "day-\(year)-\(month)-\(day)"
    }
    return scheduleID.uuidString + ":" + suffix
  }

  private static func validatedCalendar(
    trigger: Routine.Trigger, timezoneID: String, dates: [Date]
  ) throws -> Calendar {
    guard let timezone = TimeZone(identifier: timezoneID) else {
      throw WorkspaceError.invalidRoutine
    }
    for date in dates { try validate(date) }
    switch trigger {
    case .interval(let minutes):
      guard (5...525_600).contains(minutes) else { throw WorkspaceError.invalidRoutine }
    case .daily(let hour, let minute):
      guard (0...23).contains(hour), (0...59).contains(minute) else {
        throw WorkspaceError.invalidRoutine
      }
    }
    // The host may use the Buddhist calendar. Recurrence and occurrence identity do not.
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timezone
    return calendar
  }

  private static func dailyOccurrence(on day: Date, hour: Int, minute: Int, calendar: Calendar)
    throws -> Date
  {
    let start = calendar.startOfDay(for: day)
    if let result = calendar.nextDate(
      after: start.addingTimeInterval(-1),
      matching: DateComponents(hour: hour, minute: minute, second: 0),
      matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward),
      calendar.isDate(result, inSameDayAs: start)
    {
      try validate(result)
      return result
    }
    let fields: Set<Calendar.Component> = [.year, .month, .day, .hour, .minute, .second]
    var requested = calendar.dateComponents([.year, .month, .day], from: start)
    requested.hour = hour
    requested.minute = minute
    requested.second = 0
    // Some historical zones use sub-minute offsets for which nextDate returns nil even for an
    // existing time. Accept construction only after exact round-trip; normalized gaps must fail.
    if let exact = calendar.date(from: requested),
      civilKey(calendar.dateComponents(fields, from: exact)) == civilKey(requested)
    {
      try validate(exact)
      return exact
    }
    // Foundation can skip the whole day for a partial-hour gap (Lord Howe 02:15). Detect a real
    // forward offset transition and prove the requested civil time lies inside it. Use the first
    // valid instant rather than assuming DST changes are always one hour long.
    let zone = calendar.timeZone
    guard
      let transition = zone.nextDaylightSavingTimeTransition(after: start.addingTimeInterval(-1)),
      calendar.isDate(transition, inSameDayAs: start),
      zone.secondsFromGMT(for: transition)
        > zone.secondsFromGMT(for: transition.addingTimeInterval(-1)),
      let before = civilKey(
        calendar.dateComponents(fields, from: transition.addingTimeInterval(-1))),
      let after = civilKey(calendar.dateComponents(fields, from: transition)),
      let target = civilKey(requested), before.lexicographicallyPrecedes(target),
      target.lexicographicallyPrecedes(after)
    else { throw WorkspaceError.invalidRoutine }
    try validate(transition)
    return transition
  }

  private static func civilKey(_ components: DateComponents) -> [Int]? {
    guard let year = components.year, let month = components.month, let day = components.day,
      let hour = components.hour, let minute = components.minute, let second = components.second
    else { return nil }
    return [year, month, day, hour, minute, second]
  }

  private static func validate(_ date: Date) throws {
    guard date.timeIntervalSinceReferenceDate.isFinite,
      date >= .distantPast, date < .distantFuture
    else { throw WorkspaceError.invalidRoutine }
  }
}
