//
// ScheduleManager.swift
// ChargeCap
//
// MIT License
//

import Combine
import Foundation

public enum ScheduleFrequency: String, CaseIterable, Codable, Sendable, Identifiable {
    case daily = "daily"
    case weekdays = "weekdays"
    case weekends = "weekends"
    case weekly = "weekly"
    case monthly = "monthly"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .daily: return "Every Day"
        case .weekdays: return "Weekdays (Mon–Fri)"
        case .weekends: return "Weekends (Sat–Sun)"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly (1st of Month)"
        }
    }
}

public enum ScheduleActionType: String, CaseIterable, Codable, Sendable, Identifiable {
    case setChargeLimit = "set_limit"
    case startTopUp = "top_up"
    case startCalibration = "calibrate"
    case startDischarge = "discharge"
    case enableSailing = "sailing_on"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .setChargeLimit: return "Set Charge Limit"
        case .startTopUp: return "Top Up to 100%"
        case .startCalibration: return "Run Calibration Mode"
        case .startDischarge: return "Discharge to Limit"
        case .enableSailing: return "Enable Sailing Mode"
        }
    }

    public var symbolName: String {
        switch self {
        case .setChargeLimit: return "slider.horizontal.3"
        case .startTopUp: return "arrow.up.to.line.circle.fill"
        case .startCalibration: return "arrow.triangle.2.circlepath.circle.fill"
        case .startDischarge: return "arrow.down.circle.fill"
        case .enableSailing: return "sailboat.fill"
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
    public var weekday: Int // 1 = Sun ... 7 = Sat
    public var action: ScheduleActionType
    public var targetLimit: Int
    public var lastTriggeredDayKey: String?

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
        lastTriggeredDayKey: String? = nil
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
    }

    public var formattedTime: String {
        String(format: "%02d:%02d", hour, minute)
    }

    public var summaryText: String {
        let actionDesc: String
        switch action {
        case .setChargeLimit:
            actionDesc = "Set limit to \(targetLimit)%"
        case .startTopUp:
            actionDesc = "Top Up to 100%"
        case .startCalibration:
            actionDesc = "Start Calibration"
        case .startDischarge:
            actionDesc = "Discharge to \(targetLimit)%"
        case .enableSailing:
            actionDesc = "Enable Sailing Mode"
        }
        return "\(frequency.title) at \(formattedTime) · \(actionDesc)"
    }
}

@MainActor
public final class ScheduleManager: ObservableObject {
    public static let shared = ScheduleManager()

    @Published public var tasks: [ScheduledTask] = [] {
        didSet { save() }
    }

    private let storageKey = "chargecap.scheduledTasks"
    private var timer: Timer?

    private init() {
        load()
        if tasks.isEmpty {
            tasks = [
                ScheduledTask(
                    name: "Weekday Desk Limit (80%)",
                    isEnabled: true,
                    frequency: .weekdays,
                    hour: 9,
                    minute: 0,
                    action: .setChargeLimit,
                    targetLimit: 80
                ),
                ScheduledTask(
                    name: "Morning Commute Top Up",
                    isEnabled: false,
                    frequency: .weekdays,
                    hour: 7,
                    minute: 30,
                    action: .startTopUp,
                    targetLimit: 100
                ),
                ScheduledTask(
                    name: "Monthly Battery Calibration",
                    isEnabled: true,
                    frequency: .monthly,
                    hour: 10,
                    minute: 0,
                    action: .startCalibration,
                    targetLimit: 80
                )
            ]
        }
    }

    public func startScheduler() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkDueTasks(at: Date())
            }
        }
    }

    public func addTask(_ task: ScheduledTask) {
        tasks.append(task)
    }

    public func removeTask(id: UUID) {
        tasks.removeAll { $0.id == id }
    }

    public func toggleTask(id: UUID) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].isEnabled.toggle()
    }

    public func executeNow(_ task: ScheduledTask) {
        let controller = ChargeController.shared
        switch task.action {
        case .setChargeLimit:
            controller.isTopUpActive = false
            controller.setChargeLimit(task.targetLimit)
        case .startTopUp:
            controller.isTopUpActive = true
        case .startCalibration:
            controller.startCalibration()
        case .startDischarge:
            controller.setChargeLimit(task.targetLimit)
            controller.isManualDischargeActive = true
        case .enableSailing:
            Prefs.shared.sailingModeEnabled = true
            controller.evaluateAndApply()
        }
    }

    public func checkDueTasks(at date: Date) {
        let cal = Calendar.current
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: date)
        guard let year = comps.year,
              let month = comps.month,
              let day = comps.day,
              let hour = comps.hour,
              let minute = comps.minute,
              let weekday = comps.weekday else { return }

        let dayKey = String(format: "%04d-%02d-%02d", year, month, day)

        for idx in tasks.indices {
            let task = tasks[idx]
            guard task.isEnabled else { continue }
            guard task.lastTriggeredDayKey != dayKey else { continue }
            guard task.hour == hour && task.minute == minute else { continue }

            let matchesDay: Bool
            switch task.frequency {
            case .daily:
                matchesDay = true
            case .weekdays:
                matchesDay = (2...6).contains(weekday)
            case .weekends:
                matchesDay = (weekday == 1 || weekday == 7)
            case .weekly:
                matchesDay = (weekday == task.weekday)
            case .monthly:
                matchesDay = (day == 1)
            }

            if matchesDay {
                tasks[idx].lastTriggeredDayKey = dayKey
                executeNow(task)
            }
        }
    }

    private func load() {
        let store = Prefs.devMode ? (UserDefaults(suiteName: "com.chargecap.app.dev") ?? .standard) : .standard
        guard let data = store.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([ScheduledTask].self, from: data) else {
            return
        }
        tasks = decoded
    }

    private func save() {
        let store = Prefs.devMode ? (UserDefaults(suiteName: "com.chargecap.app.dev") ?? .standard) : .standard
        if let data = try? JSONEncoder().encode(tasks) {
            store.set(data, forKey: storageKey)
        }
    }
}
