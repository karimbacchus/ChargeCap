//
// ScheduleManager.swift
// ChargeCap
//
// MIT License
//

import AppKit
import ChargeCapCore
import Combine
import Foundation

public enum ScheduleFrequency: String, CaseIterable, Codable, Sendable, Identifiable {
    case daily = "daily"
    case weekdays = "weekdays"
    case weekends = "weekends"
    case weekly = "weekly"
    case monthly = "monthly"
    case customDays = "custom_days"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .daily: return "Every Day"
        case .weekdays: return "Weekdays (Mon–Fri)"
        case .weekends: return "Weekends (Sat–Sun)"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly (1st of Month)"
        case .customDays: return "Custom Days"
        }
    }
}

public enum ScheduleActionType: String, CaseIterable, Codable, Sendable, Identifiable {
    case setChargeLimit = "set_limit"
    case startTopUp = "top_up"
    case startCalibration = "calibrate"
    case startDischarge = "discharge"
    case enableSailing = "sailing_on"
    case disableSailing = "sailing_off"
    case stopDischarge = "stop_discharge"
    case lowPowerModeOn = "lpm_on"
    case lowPowerModeOff = "lpm_off"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .setChargeLimit: return "Set Charge Limit"
        case .startTopUp: return "Top Up to 100%"
        case .startCalibration: return "Run Calibration Mode"
        case .startDischarge: return "Discharge to Limit"
        case .enableSailing: return "Enable Sailing Mode"
        case .disableSailing: return "Disable Sailing Mode"
        case .stopDischarge: return "Stop Discharging"
        case .lowPowerModeOn: return "Turn Low Power Mode On"
        case .lowPowerModeOff: return "Turn Low Power Mode Off"
        }
    }

    public var symbolName: String {
        switch self {
        case .setChargeLimit: return "slider.horizontal.3"
        case .startTopUp: return "arrow.up.to.line.circle.fill"
        case .startCalibration: return "arrow.triangle.2.circlepath.circle.fill"
        case .startDischarge: return "arrow.down.circle.fill"
        case .enableSailing: return "sailboat.fill"
        case .disableSailing: return "sailboat"
        case .stopDischarge: return "stop.circle.fill"
        case .lowPowerModeOn: return "leaf.fill"
        case .lowPowerModeOff: return "leaf"
        }
    }
}

public struct ScheduledTask: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    public var frequency: ScheduleFrequency
    public var hour: Int
    public var minute: Int
    public var weekday: Int // 1 = Sun ... 7 = Sat (used by .weekly)
    public var action: ScheduleActionType
    public var targetLimit: Int
    /// Legacy marker kept for backward compatibility; `lastTriggeredAt` is authoritative.
    public var lastTriggeredDayKey: String?
    /// Days used by `.customDays` (1 = Sun ... 7 = Sat).
    public var weekdays: Set<Int>
    /// The scheduled occurrence (not the wall-clock fire time) most recently handled.
    public var lastTriggeredAt: Date?
    /// Occurrences earlier than this are never caught up (set when a task is created/enabled).
    public var armedAt: Date?

    public static let defaultCustomDays: Set<Int> = [2, 3, 4, 5, 6]

    public init(
        id: UUID = UUID(),
        name: String,
        isEnabled: Bool = true,
        frequency: ScheduleFrequency = .daily,
        hour: Int = 8,
        minute: Int = 0,
        weekday: Int = 2,
        action: ScheduleActionType = .setChargeLimit,
        targetLimit: Int = 80,
        lastTriggeredDayKey: String? = nil,
        weekdays: Set<Int> = ScheduledTask.defaultCustomDays,
        lastTriggeredAt: Date? = nil,
        armedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.frequency = frequency
        self.hour = hour
        self.minute = minute
        self.weekday = weekday
        self.action = action
        self.targetLimit = targetLimit
        self.lastTriggeredDayKey = lastTriggeredDayKey
        self.weekdays = weekdays
        self.lastTriggeredAt = lastTriggeredAt
        self.armedAt = armedAt
    }

    // Tolerant decoding: tasks saved by older versions lack the newer keys.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Scheduled Task"
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        frequency = try c.decodeIfPresent(ScheduleFrequency.self, forKey: .frequency) ?? .daily
        hour = try c.decodeIfPresent(Int.self, forKey: .hour) ?? 8
        minute = try c.decodeIfPresent(Int.self, forKey: .minute) ?? 0
        weekday = try c.decodeIfPresent(Int.self, forKey: .weekday) ?? 2
        action = try c.decodeIfPresent(ScheduleActionType.self, forKey: .action) ?? .setChargeLimit
        targetLimit = try c.decodeIfPresent(Int.self, forKey: .targetLimit) ?? 80
        lastTriggeredDayKey = try c.decodeIfPresent(String.self, forKey: .lastTriggeredDayKey)
        weekdays = try c.decodeIfPresent(Set<Int>.self, forKey: .weekdays) ?? ScheduledTask.defaultCustomDays
        lastTriggeredAt = try c.decodeIfPresent(Date.self, forKey: .lastTriggeredAt)
        armedAt = try c.decodeIfPresent(Date.self, forKey: .armedAt)
    }

    public var formattedTime: String {
        String(format: "%02d:%02d", hour, minute)
    }

    /// Pure recurrence description used for occurrence math.
    public var recurrence: ScheduleRecurrence {
        switch frequency {
        case .daily: return .daily
        case .weekdays: return .weekdays([2, 3, 4, 5, 6])
        case .weekends: return .weekdays([1, 7])
        case .weekly: return .weekdays([weekday])
        case .monthly: return .dayOfMonth(1)
        case .customDays: return .weekdays(weekdays)
        }
    }

    public var actionSummary: String {
        switch action {
        case .setChargeLimit: return "Set limit to \(targetLimit)%"
        case .startTopUp: return "Top Up to 100%"
        case .startCalibration: return "Start Calibration"
        case .startDischarge: return "Discharge to \(targetLimit)%"
        case .enableSailing: return "Enable Sailing Mode"
        case .disableSailing: return "Disable Sailing Mode"
        case .stopDischarge: return "Stop Discharging"
        case .lowPowerModeOn: return "Low Power Mode On"
        case .lowPowerModeOff: return "Low Power Mode Off"
        }
    }

    public var frequencyText: String {
        switch frequency {
        case .customDays:
            let symbols = Calendar.current.shortWeekdaySymbols
            let names = weekdays.sorted().compactMap { (1...7).contains($0) ? symbols[$0 - 1] : nil }
            return names.isEmpty ? "No days selected" : names.joined(separator: ", ")
        case .weekly:
            let symbols = Calendar.current.weekdaySymbols
            return (1...7).contains(weekday) ? "Every \(symbols[weekday - 1])" : frequency.title
        default:
            return frequency.title
        }
    }

    public var summaryText: String {
        "\(frequencyText) at \(formattedTime) · \(actionSummary)"
    }
}

/// One entry of the schedule history.
public struct ScheduleRun: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var taskID: UUID
    public var taskName: String
    public var actionTitle: String
    public var firedAt: Date
    public var wasCatchUp: Bool
    public var result: String

    public init(id: UUID = UUID(), taskID: UUID, taskName: String, actionTitle: String,
                firedAt: Date = Date(), wasCatchUp: Bool = false, result: String) {
        self.id = id
        self.taskID = taskID
        self.taskName = taskName
        self.actionTitle = actionTitle
        self.firedAt = firedAt
        self.wasCatchUp = wasCatchUp
        self.result = result
    }
}

public struct UpcomingScheduledTask: Identifiable, Equatable, Sendable {
    public var task: ScheduledTask
    public var date: Date
    public var id: UUID { task.id }
}

@MainActor
public final class ScheduleManager: ObservableObject {
    public static let shared = ScheduleManager()

    @Published public var tasks: [ScheduledTask] = [] {
        didSet {
            armNewlyEnabledTasks(old: oldValue)
            save()
        }
    }

    /// Most recent runs first; capped at `maxHistory`.
    @Published public private(set) var history: [ScheduleRun] = []

    public static let maxHistory = 100
    /// A scheduled minute is "live" for this long; later detection counts as a catch-up.
    private static let liveWindow: TimeInterval = 120
    private static let catchUpWindow: TimeInterval = 24 * 3600

    private let storageKey = "chargecap.scheduledTasks"
    private let historyKey = "chargecap.scheduleHistory"
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var isArming = false

    private init() {
        load()
        if tasks.isEmpty && !hasStoredTasks {
            let now = Date()
            tasks = [
                ScheduledTask(
                    name: "Weekday Desk Limit (80%)",
                    isEnabled: true,
                    frequency: .weekdays,
                    hour: 9,
                    minute: 0,
                    action: .setChargeLimit,
                    targetLimit: 80,
                    armedAt: now
                ),
                ScheduledTask(
                    name: "Morning Commute Top Up",
                    isEnabled: false,
                    frequency: .weekdays,
                    hour: 7,
                    minute: 30,
                    action: .startTopUp,
                    targetLimit: 100,
                    armedAt: now
                ),
                ScheduledTask(
                    name: "Monthly Battery Calibration",
                    isEnabled: true,
                    frequency: .monthly,
                    hour: 10,
                    minute: 0,
                    action: .startCalibration,
                    targetLimit: 80,
                    armedAt: now
                )
            ]
        }
    }

    // MARK: - Lifecycle

    public func startScheduler() {
        timer?.invalidate()
        let t = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkDueTasks(at: Date())
            }
        }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        timer = t

        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    // Give the system a moment to settle after wake.
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    self?.runCatchUp(at: Date())
                }
            }
        }
        // Launch: catch up anything missed while the app was not running.
        runCatchUp(at: Date())
    }

    // MARK: - Task management

    public func addTask(_ task: ScheduledTask) {
        var t = task
        if t.armedAt == nil { t.armedAt = Date() }
        tasks.append(t)
    }

    public func removeTask(id: UUID) {
        tasks.removeAll { $0.id == id }
    }

    public func toggleTask(id: UUID) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].isEnabled.toggle()
    }

    public func clearHistory() {
        history = []
        saveHistory()
    }

    // MARK: - Upcoming

    /// The next time `task` will run after `date`, or nil when disabled/unschedulable.
    public func nextOccurrence(of task: ScheduledTask, after date: Date = Date()) -> Date? {
        guard task.isEnabled else { return nil }
        return ScheduleCalculator.nextOccurrence(after: date, hour: task.hour, minute: task.minute,
                                                 recurrence: task.recurrence)
    }

    /// The enabled task that will run soonest.
    public var nextUpcomingTask: UpcomingScheduledTask? {
        let now = Date()
        return tasks.compactMap { task -> UpcomingScheduledTask? in
            guard let d = nextOccurrence(of: task, after: now) else { return nil }
            return UpcomingScheduledTask(task: task, date: d)
        }.min { $0.date < $1.date }
    }

    // MARK: - Execution

    /// Runs a task immediately (also used by the "Run now" UI). Returns the result message.
    @discardableResult
    public func executeNow(_ task: ScheduledTask) -> String {
        perform(task)
    }

    private func perform(_ task: ScheduledTask) -> String {
        let controller = ChargeController.shared
        switch task.action {
        case .setChargeLimit:
            controller.isTopUpActive = false
            controller.setChargeLimit(task.targetLimit)
            return "Charge limit set to \(task.targetLimit)%"
        case .startTopUp:
            controller.isTopUpActive = true
            return "Top Up started"
        case .startCalibration:
            controller.startCalibration()
            return "Calibration started"
        case .startDischarge:
            controller.setChargeLimit(task.targetLimit)
            controller.isManualDischargeActive = true
            return "Discharging to \(task.targetLimit)%"
        case .enableSailing:
            Prefs.shared.sailingModeEnabled = true
            controller.evaluateAndApply()
            return "Sailing Mode enabled"
        case .disableSailing:
            Prefs.shared.sailingModeEnabled = false
            controller.evaluateAndApply()
            return "Sailing Mode disabled"
        case .stopDischarge:
            controller.setManualDischarge(false)
            return "Discharge stopped"
        case .lowPowerModeOn, .lowPowerModeOff:
            let on = task.action == .lowPowerModeOn
            // A scheduled action overrides the standing policy, otherwise the controller
            // would immediately re-apply the old policy.
            let hadPolicy = Prefs.shared.lowPowerModePolicy != .unmanaged
            Prefs.shared.lowPowerModePolicy = .unmanaged
            if !Prefs.devMode {
                HelperClient.shared.setLowPowerMode(on, scope: .all)
            }
            var msg = "Low Power Mode turned \(on ? "on" : "off")"
            if hadPolicy { msg += " (Low Power Mode policy reset to Managed by macOS)" }
            return msg
        }
    }

    public func checkDueTasks(at date: Date) {
        processDue(at: date, allowCatchUp: false)
    }

    /// Runs tasks whose latest occurrence in the last 24 h was missed. No-op unless enabled in Prefs.
    public func runCatchUp(at date: Date) {
        guard Prefs.shared.scheduleCatchUpMissed else {
            // Still fire anything that is live right now.
            processDue(at: date, allowCatchUp: false)
            return
        }
        processDue(at: date, allowCatchUp: true)
    }

    private func processDue(at now: Date, allowCatchUp: Bool) {
        for idx in tasks.indices {
            let task = tasks[idx]
            guard task.isEnabled,
                  let latest = ScheduleCalculator.mostRecentOccurrence(
                    onOrBefore: now, hour: task.hour, minute: task.minute, recurrence: task.recurrence)
            else { continue }

            if let armed = task.armedAt, latest < armed.addingTimeInterval(-60) { continue }
            if let last = task.lastTriggeredAt, last >= latest { continue }

            let age = now.timeIntervalSince(latest)
            let isLive = age < Self.liveWindow
            let isCatchUp = !isLive && allowCatchUp && age <= Self.catchUpWindow
            guard isLive || isCatchUp else { continue }

            isArming = true
            tasks[idx].lastTriggeredAt = latest
            tasks[idx].lastTriggeredDayKey = Self.dayKey(for: latest)
            isArming = false

            let result = perform(task)
            record(task: task, firedAt: now, wasCatchUp: isCatchUp, result: result)
        }
    }

    private func record(task: ScheduledTask, firedAt: Date, wasCatchUp: Bool, result: String) {
        let run = ScheduleRun(taskID: task.id, taskName: task.name, actionTitle: task.action.title,
                              firedAt: firedAt, wasCatchUp: wasCatchUp, result: result)
        history.insert(run, at: 0)
        if history.count > Self.maxHistory { history.removeLast(history.count - Self.maxHistory) }
        saveHistory()
        if Prefs.shared.notifySchedule {
            ChargeController.shared.postNotification(
                title: wasCatchUp ? "Missed schedule ran: \(task.name)" : "Schedule: \(task.name)",
                body: result)
        }
    }

    private static func dayKey(for date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// When a task is switched on, ignore occurrences from before that moment.
    private func armNewlyEnabledTasks(old: [ScheduledTask]) {
        guard !isArming else { return }
        let oldByID = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
        var changed = false
        var updated = tasks
        for i in updated.indices {
            let t = updated[i]
            let was = oldByID[t.id]
            if t.isEnabled && (was == nil ? t.armedAt == nil : !(was!.isEnabled) ) {
                updated[i].armedAt = Date()
                changed = true
            }
        }
        if changed {
            isArming = true
            tasks = updated
            isArming = false
        }
    }

    // MARK: - Persistence

    private var store: UserDefaults {
        Prefs.devMode ? (UserDefaults(suiteName: "com.chargecap.app.dev") ?? .standard) : .standard
    }

    private var hasStoredTasks: Bool { store.data(forKey: storageKey) != nil }

    private func load() {
        let s = store
        if let data = s.data(forKey: storageKey),
           var decoded = try? JSONDecoder().decode([ScheduledTask].self, from: data) {
            // Migration: tasks saved before catch-up existed get armed now, so history is not replayed.
            let now = Date()
            for i in decoded.indices where decoded[i].armedAt == nil { decoded[i].armedAt = now }
            isArming = true
            tasks = decoded
            isArming = false
        }
        if let data = s.data(forKey: historyKey),
           let decoded = try? JSONDecoder().decode([ScheduleRun].self, from: data) {
            history = Array(decoded.prefix(Self.maxHistory))
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(tasks) {
            store.set(data, forKey: storageKey)
        }
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(history) {
            store.set(data, forKey: historyKey)
        }
    }
}
