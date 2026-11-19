//
// ScheduleCalculator.swift
// ChargeCapCore
//
// Pure, DST-safe occurrence math for recurring schedules.
//

import Foundation

/// Which days a schedule applies to. Weekday numbers follow `Calendar` (1 = Sunday ... 7 = Saturday).
public enum ScheduleRecurrence: Equatable, Sendable {
    case daily
    case weekdays(Set<Int>)
    case dayOfMonth(Int)

    func matches(_ date: Date, calendar: Calendar) -> Bool {
        switch self {
        case .daily: return true
        case .weekdays(let set): return set.contains(calendar.component(.weekday, from: date))
        case .dayOfMonth(let d): return calendar.component(.day, from: date) == d
        }
    }
}

public enum ScheduleCalculator {
    /// Latest occurrence at or before `date` within `lookbackDays` (default 62), or nil.
    public static func mostRecentOccurrence(
        onOrBefore date: Date, hour: Int, minute: Int, recurrence: ScheduleRecurrence,
        calendar: Calendar = .current, lookbackDays: Int = 62
    ) -> Date? {
        let startOfDay = calendar.startOfDay(for: date)
        for offset in 0...lookbackDays {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: startOfDay),
                  recurrence.matches(day, calendar: calendar),
                  let candidate = calendar.date(bySettingHour: hour, minute: minute, second: 0,
                                                of: day, matchingPolicy: .nextTime),
                  calendar.isDate(candidate, inSameDayAs: day),
                  candidate <= date else { continue }
            return candidate
        }
        return nil
    }

    /// First occurrence strictly after `date` within `lookaheadDays` (default 400), or nil.
    public static func nextOccurrence(
        after date: Date, hour: Int, minute: Int, recurrence: ScheduleRecurrence,
        calendar: Calendar = .current, lookaheadDays: Int = 400
    ) -> Date? {
        let startOfDay = calendar.startOfDay(for: date)
        for offset in 0...lookaheadDays {
            guard let day = calendar.date(byAdding: .day, value: offset, to: startOfDay),
                  recurrence.matches(day, calendar: calendar),
                  let candidate = calendar.date(bySettingHour: hour, minute: minute, second: 0,
                                                of: day, matchingPolicy: .nextTime),
                  calendar.isDate(candidate, inSameDayAs: day),
                  candidate > date else { continue }
            return candidate
        }
        return nil
    }
}
