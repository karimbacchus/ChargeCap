import Foundation
import Testing
@testable import ChargeCapCore

private func cal(_ tz: String = "UTC") -> Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: tz)!
    return c
}
private func date(_ c: Calendar, _ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) -> Date {
    c.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

@Suite struct ScheduleCalculatorTests {
    // 2026-11-18 is a Wednesday.
    @Test func dailyMostRecentToday() {
        let c = cal()
        let r = ScheduleCalculator.mostRecentOccurrence(onOrBefore: date(c, 2026, 11, 18, 10, 30), hour: 9, minute: 0, recurrence: .daily, calendar: c)
        #expect(r == date(c, 2026, 11, 18, 9, 0))
    }

    @Test func dailyMostRecentYesterdayWhenNotYetToday() {
        let c = cal()
        let r = ScheduleCalculator.mostRecentOccurrence(onOrBefore: date(c, 2026, 11, 18, 8, 0), hour: 9, minute: 0, recurrence: .daily, calendar: c)
        #expect(r == date(c, 2026, 11, 17, 9, 0))
    }

    @Test func exactMinuteCountsAsOccurrence() {
        let c = cal()
        let t = date(c, 2026, 11, 18, 9, 0)
        #expect(ScheduleCalculator.mostRecentOccurrence(onOrBefore: t, hour: 9, minute: 0, recurrence: .daily, calendar: c) == t)
        #expect(ScheduleCalculator.nextOccurrence(after: t, hour: 9, minute: 0, recurrence: .daily, calendar: c) == date(c, 2026, 11, 19, 9, 0))
    }

    @Test func weekdaysSkipsWeekend() {
        let c = cal()
        let weekdays: Set<Int> = [2, 3, 4, 5, 6]
        // Saturday 2026-11-21 noon -> most recent is Friday 20th.
        #expect(ScheduleCalculator.mostRecentOccurrence(onOrBefore: date(c, 2026, 11, 21, 12), hour: 9, minute: 0, recurrence: .weekdays(weekdays), calendar: c) == date(c, 2026, 11, 20, 9, 0))
        // Next after Friday 10:00 is Monday 23rd.
        #expect(ScheduleCalculator.nextOccurrence(after: date(c, 2026, 11, 20, 10), hour: 9, minute: 0, recurrence: .weekdays(weekdays), calendar: c) == date(c, 2026, 11, 23, 9, 0))
    }

    @Test func weeklySingleDay() {
        let c = cal()
        // Wednesday 18th, task on Mondays (2).
        #expect(ScheduleCalculator.nextOccurrence(after: date(c, 2026, 11, 18, 12), hour: 7, minute: 30, recurrence: .weekdays([2]), calendar: c) == date(c, 2026, 11, 23, 7, 30))
        #expect(ScheduleCalculator.mostRecentOccurrence(onOrBefore: date(c, 2026, 11, 18, 12), hour: 7, minute: 30, recurrence: .weekdays([2]), calendar: c) == date(c, 2026, 11, 16, 7, 30))
    }

    @Test func customDays() {
        let c = cal()
        let days: Set<Int> = [1, 4, 7] // Sun, Wed, Sat
        #expect(ScheduleCalculator.nextOccurrence(after: date(c, 2026, 11, 18, 12), hour: 8, minute: 0, recurrence: .weekdays(days), calendar: c) == date(c, 2026, 11, 21, 8, 0))
    }

    @Test func emptyCustomDaysHasNoOccurrence() {
        let c = cal()
        #expect(ScheduleCalculator.nextOccurrence(after: date(c, 2026, 11, 18), hour: 8, minute: 0, recurrence: .weekdays([]), calendar: c) == nil)
    }

    @Test func monthlyFirst() {
        let c = cal()
        #expect(ScheduleCalculator.nextOccurrence(after: date(c, 2026, 11, 18), hour: 10, minute: 0, recurrence: .dayOfMonth(1), calendar: c) == date(c, 2026, 12, 1, 10, 0))
        #expect(ScheduleCalculator.mostRecentOccurrence(onOrBefore: date(c, 2026, 11, 18), hour: 10, minute: 0, recurrence: .dayOfMonth(1), calendar: c) == date(c, 2026, 11, 1, 10, 0))
    }

    @Test func monthlyAcrossYear() {
        let c = cal()
        #expect(ScheduleCalculator.nextOccurrence(after: date(c, 2026, 12, 15), hour: 10, minute: 0, recurrence: .dayOfMonth(1), calendar: c) == date(c, 2027, 1, 1, 10, 0))
    }

    @Test func springForwardGapRunsOnce() {
        let c = cal("America/New_York")
        // 2026-03-08: 02:30 does not exist in New York.
        let next = ScheduleCalculator.nextOccurrence(after: date(c, 2026, 3, 7, 12), hour: 2, minute: 30, recurrence: .daily, calendar: c)
        #expect(next != nil)
        #expect(c.isDate(next!, inSameDayAs: date(c, 2026, 3, 8, 12)))
        let after = ScheduleCalculator.nextOccurrence(after: next!, hour: 2, minute: 30, recurrence: .daily, calendar: c)
        #expect(after == date(c, 2026, 3, 9, 2, 30))
    }

    @Test func fallBackDayHasSingleOccurrence() {
        let c = cal("America/New_York")
        // 2026-11-01 01:30 happens twice; we must see exactly one occurrence per day.
        let first = ScheduleCalculator.nextOccurrence(after: date(c, 2026, 10, 31, 12), hour: 1, minute: 30, recurrence: .daily, calendar: c)!
        let second = ScheduleCalculator.nextOccurrence(after: first, hour: 1, minute: 30, recurrence: .daily, calendar: c)!
        #expect(c.isDate(first, inSameDayAs: date(c, 2026, 11, 1, 12)))
        #expect(c.isDate(second, inSameDayAs: date(c, 2026, 11, 2, 12)))
    }
}
