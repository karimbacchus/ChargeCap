//
// ChargeController.swift
// ChargeCap
//
// MIT License
//

import AppKit
import ChargeCapCore
import Combine
import Foundation
import UserNotifications

public enum CalibrationPhase: Int, CaseIterable, Codable, Sendable, Identifiable {
    case chargeToFullFirst = 1
    case dischargeTo15 = 2
    case chargeToFullSecond = 3
    case holdAt100 = 4
    case restoreToLimit = 5

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .chargeToFullFirst: return "Step 1/5 · Charge to 100%"
        case .dischargeTo15: return "Step 2/5 · Discharge to 15%"
        case .chargeToFullSecond: return "Step 3/5 · Recharge to 100%"
        case .holdAt100: return "Step 4/5 · Hold at 100% (1 hr)"
        case .restoreToLimit: return "Step 5/5 · Restore to Limit"
        }
    }

    public var shortTitle: String {
        switch self {
        case .chargeToFullFirst: return "Charging → 100%"
        case .dischargeTo15: return "Discharging → 15%"
        case .chargeToFullSecond: return "Recharging → 100%"
        case .holdAt100: return "Holding 100%"
        case .restoreToLimit: return "Restoring Limit"
        }
    }
}

public enum OperatingMode: Equatable, Sendable {
    case chargingToLimit(target: Int)
    case holdingAtLimit(limit: Int)
    case sailing(lowerBound: Int, upperBound: Int)
    case discharging(target: Int, automatic: Bool)
    case topUp
    case calibrating(CalibrationPhase)
    case heatProtectionPaused(tempC: Double, maxC: Double)
    case onBattery
    case sleepingPaused

    public var badgeText: String {
        switch self {
        case .chargingToLimit(let target):
            return "Charging to \(target)%"
        case .holdingAtLimit(let limit):
            return "Paused at \(limit)%"
        case .sailing(let low, let high):
            return "Sailing (\(low)–\(high)%)"
        case .discharging(let target, let auto):
            return auto ? "Auto-Discharging to \(target)%" : "Discharging to \(target)%"
        case .topUp:
            return "Top Up to 100%"
        case .calibrating(let phase):
            return "Calibration · \(phase.shortTitle)"
        case .heatProtectionPaused(let tempC, _):
            return String(format: "Heat Protection (%.1f°C)", tempC)
        case .onBattery:
            return "Running on Battery"
        case .sleepingPaused:
            return "Sleep Charge Inhibit"
        }
    }

    public var symbolName: String {
        switch self {
        case .chargingToLimit: return "bolt.fill"
        case .holdingAtLimit: return "pause.circle.fill"
        case .sailing: return "sailboat.fill"
        case .discharging: return "arrow.down.circle.fill"
        case .topUp: return "arrow.up.to.line.circle.fill"
        case .calibrating: return "arrow.triangle.2.circlepath.circle.fill"
        case .heatProtectionPaused: return "flame.fill"
        case .onBattery: return "battery.75percent"
        case .sleepingPaused: return "moon.zzz.fill"
        }
    }
}

public struct TelemetryHistoryPoint: Identifiable, Sendable {
    public let id = UUID()
    public let timestamp: Date
    public let osPercent: Double
    public let hwPercent: Double
    public let batteryWatts: Double
    public let adapterWatts: Double
    public let systemWatts: Double
    public let temperatureC: Double
}

@MainActor
public final class ChargeController: ObservableObject {
    public static let shared = ChargeController()

    @Published public private(set) var snapshot: BatterySnapshot
    @Published public private(set) var operatingMode: OperatingMode = .holdingAtLimit(limit: 80)
    @Published public var isTopUpActive: Bool = false {
        didSet { evaluateAndApply() }
    }
    @Published public var isManualDischargeActive: Bool = false {
        didSet { evaluateAndApply() }
    }
    @Published public private(set) var calibrationPhase: CalibrationPhase? = nil
    @Published public private(set) var calibrationHoldStart: Date? = nil
    @Published public private(set) var calibrationStartedAt: Date? = nil
    @Published public private(set) var isHeatPaused: Bool = false
    @Published public private(set) var history: [TelemetryHistoryPoint] = []
    @Published public private(set) var lastActionSummary: String = "Monitoring battery telemetry"

    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var wasPluggedIn: Bool = true
    private var wasBelowLimit: Bool = false

    public var isCalibrating: Bool {
        calibrationPhase != nil
    }

    public var calibrationHoldRemainingSeconds: Int {
        guard calibrationPhase == .holdAt100, let start = calibrationHoldStart else { return 0 }
        let elapsed = Int(Date().timeIntervalSince(start))
        return max(0, 3600 - elapsed)
    }

    private init() {
        let initial = BatteryTelemetryReader.readSnapshot()
        self.snapshot = initial
        self.wasPluggedIn = initial.isPluggedIn
        appendHistory(from: initial)

        // Observe preference changes
        Prefs.shared.objectWillChange
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.evaluateAndApply()
            }
            .store(in: &cancellables)

        registerSleepWakeNotifications()
    }

    public func startMonitoring() {
        HelperClient.shared.checkHelperStatus()
        refreshNow()

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshNow()
            }
        }
    }

    public func refreshNow() {
        let latest = BatteryTelemetryReader.readSnapshot()
        handlePlugTransition(previous: wasPluggedIn, current: latest.isPluggedIn)
        wasPluggedIn = latest.isPluggedIn
        self.snapshot = latest
        appendHistory(from: latest)
        evaluateAndApply()
    }

    public func evaluateWithSnapshot(_ customSnapshot: BatterySnapshot) {
        self.snapshot = customSnapshot
        evaluateAndApply()
    }

    // MARK: - User Actions

    public func toggleTopUp() {
        if isTopUpActive {
            isTopUpActive = false
        } else {
            isManualDischargeActive = false
            calibrationPhase = nil
            isTopUpActive = true
        }
    }

    public func toggleManualDischarge() {
        if isManualDischargeActive {
            isManualDischargeActive = false
        } else {
            isTopUpActive = false
            calibrationPhase = nil
            isManualDischargeActive = true
        }
    }

    public func startCalibration() {
        isTopUpActive = false
        isManualDischargeActive = false
        calibrationStartedAt = Date()
        calibrationHoldStart = nil
        calibrationPhase = .chargeToFullFirst
        evaluateAndApply()
    }

    public func advanceCalibrationStep() {
        guard let phase = calibrationPhase else { return }
        switch phase {
        case .chargeToFullFirst:
            calibrationPhase = .dischargeTo15
        case .dischargeTo15:
            calibrationPhase = .chargeToFullSecond
        case .chargeToFullSecond:
            calibrationHoldStart = Date()
            calibrationPhase = .holdAt100
        case .holdAt100:
            calibrationPhase = .restoreToLimit
        case .restoreToLimit:
            calibrationPhase = nil
            calibrationStartedAt = nil
            calibrationHoldStart = nil
        }
        evaluateAndApply()
    }

    public func stopCalibration() {
        calibrationPhase = nil
        calibrationHoldStart = nil
        calibrationStartedAt = nil
        evaluateAndApply()
    }

    public func setChargeLimit(_ newLimit: Int) {
        Prefs.shared.chargeLimit = newLimit
        evaluateAndApply()
    }

    // MARK: - Core Control State Machine

    public func evaluateAndApply() {
        let prefs = Prefs.shared
        let helper = HelperClient.shared
        let currentLevel = snapshot.percentage(useHardware: prefs.useHardwarePercentage)
        let currentInt = Int(currentLevel.rounded())
        let limit = prefs.chargeLimit

        // Classic Intel BCLM key support if explicitly toggled
        if prefs.useClassicIntelKey {
            helper.setClassicMaxCharge(UInt8(limit))
        }

        // 1. Check Thermal / Heat Protection with 2.0 C hysteresis
        if prefs.heatProtectionEnabled {
            if snapshot.batteryTemperatureC >= prefs.heatProtectionMaxCelsius {
                if !isHeatPaused {
                    isHeatPaused = true
                    sendNotification(
                        title: "Heat Protection Activated",
                        body: "Battery reached \(prefs.formatTemperature(snapshot.batteryTemperatureC)). Charging paused until it cools down."
                    )
                }
            } else if isHeatPaused && snapshot.batteryTemperatureC <= (prefs.heatProtectionMaxCelsius - 2.0) {
                isHeatPaused = false
            }
        } else {
            isHeatPaused = false
        }

        // 2. If unplugged and not force-discharging, we are simply on battery
        if !snapshot.isPluggedIn && !snapshot.forceDischargingBySMC {
            operatingMode = .onBattery
            helper.setPreventSleep(false)
            lastActionSummary = "On battery power (\(currentInt)%)"
            return
        }

        // 3. Heat Protection overrides charging
        if isHeatPaused {
            operatingMode = .heatProtectionPaused(
                tempC: snapshot.batteryTemperatureC,
                maxC: prefs.heatProtectionMaxCelsius
            )
            helper.setForceDischarge(false)
            helper.setChargingEnabled(false)
            syncMagSafeLED(for: operatingMode)
            lastActionSummary = "Charging paused by Heat Protection (\(prefs.formatTemperature(snapshot.batteryTemperatureC)))"
            return
        }

        // 4. Calibration Mode State Machine
        if let calPhase = calibrationPhase {
            handleCalibrationPhase(calPhase, currentInt: currentInt, limit: limit)
            return
        }

        // 5. Top Up Mode (Charge to 100%)
        if isTopUpActive {
            if currentInt >= 100 && prefs.topUpAutoRevertAt100 {
                isTopUpActive = false
                sendNotification(
                    title: "Top Up Complete",
                    body: "Battery reached 100%. Returning to \(limit)% charge limit."
                )
            } else {
                operatingMode = .topUp
                helper.setForceDischarge(false)
                helper.setChargingEnabled(true)
                helper.setPreventSleep(prefs.disableSleepUntilChargeLimit, reason: "ChargeCap Top Up")
                syncMagSafeLED(for: operatingMode)
                lastActionSummary = "Topping up battery to 100% (currently \(currentInt)%)"
                return
            }
        }

        // 6. Manual or Automatic Discharge when above limit
        let shouldAutoDischarge = prefs.autoDischargeEnabled && currentInt > limit
        if isManualDischargeActive || shouldAutoDischarge {
            if currentInt <= limit {
                // Reached target limit: stop discharging and hold at limit
                if isManualDischargeActive {
                    isManualDischargeActive = false
                    sendNotification(
                        title: "Discharge Complete",
                        body: "Battery discharged to target \(limit)%."
                    )
                }
                operatingMode = .holdingAtLimit(limit: limit)
                helper.setForceDischarge(false)
                helper.setChargingEnabled(false)
                helper.setPreventSleep(false)
                syncMagSafeLED(for: operatingMode)
                lastActionSummary = "Reached \(limit)% limit · Holding on adapter power"
                return
            } else {
                operatingMode = .discharging(target: limit, automatic: !isManualDischargeActive)
                helper.setForceDischarge(true)
                helper.setPreventSleep(prefs.dischargeInClamshell, reason: "ChargeCap Active Discharge")
                syncMagSafeLED(for: operatingMode)
                lastActionSummary = "Actively discharging to \(limit)% (currently \(currentInt)%)"
                return
            }
        }

        // 7. Standard Charge Limiter + Sailing Mode
        let sailLower = prefs.sailingModeEnabled ? prefs.sailingTarget : limit

        if currentInt < sailLower {
            // Below Charge Limit (and below Sailing lower bound): Enable Charging
            operatingMode = .chargingToLimit(target: limit)
            helper.setForceDischarge(false)
            helper.setChargingEnabled(true)
            helper.setPreventSleep(prefs.disableSleepUntilChargeLimit, reason: "ChargeCap Charging to Limit")
            wasBelowLimit = true
            lastActionSummary = "Charging toward \(limit)% limit"
        } else if currentInt >= limit {
            // At or above Charge Limit: Inhibit Charging
            if wasBelowLimit && currentInt == limit {
                wasBelowLimit = false
                sendNotification(
                    title: "Charge Limit Reached (\(limit)%)",
                    body: "MacBook is now powered directly by the adapter."
                )
            }
            if prefs.sailingModeEnabled && currentInt > limit {
                operatingMode = .sailing(lowerBound: sailLower, upperBound: limit)
                lastActionSummary = "Above \(limit)% · Sailing active (\(sailLower)–\(limit)%)"
            } else {
                operatingMode = .holdingAtLimit(limit: limit)
                lastActionSummary = "Holding battery at \(limit)% on adapter power"
            }
            helper.setForceDischarge(false)
            helper.setChargingEnabled(false)
            helper.setPreventSleep(false)
        } else {
            // Inside the Sailing window: sailLower <= currentInt < limit
            // If we were actively charging up from below sailLower, keep charging until we hit `limit`.
            // Otherwise, sail without charging!
            if case .chargingToLimit = operatingMode {
                operatingMode = .chargingToLimit(target: limit)
                helper.setForceDischarge(false)
                helper.setChargingEnabled(true)
                helper.setPreventSleep(prefs.disableSleepUntilChargeLimit, reason: "ChargeCap Charging to Limit")
                lastActionSummary = "Charging through sailing band to \(limit)%"
            } else {
                operatingMode = .sailing(lowerBound: sailLower, upperBound: limit)
                helper.setForceDischarge(false)
                helper.setChargingEnabled(false)
                helper.setPreventSleep(false)
                lastActionSummary = "Sailing between \(sailLower)% and \(limit)% (no micro-charging)"
            }
        }

        syncMagSafeLED(for: operatingMode)
    }

    private func handleCalibrationPhase(_ phase: CalibrationPhase, currentInt: Int, limit: Int) {
        let helper = HelperClient.shared
        switch phase {
        case .chargeToFullFirst:
            if currentInt >= 100 {
                calibrationPhase = .dischargeTo15
                handleCalibrationPhase(.dischargeTo15, currentInt: currentInt, limit: limit)
                return
            }
            operatingMode = .calibrating(.chargeToFullFirst)
            helper.setForceDischarge(false)
            helper.setChargingEnabled(true)
            helper.setPreventSleep(true, reason: "ChargeCap Calibration Step 1")
            lastActionSummary = "Calibration 1/5: Charging to 100% (\(currentInt)%)"

        case .dischargeTo15:
            if currentInt <= 15 {
                calibrationPhase = .chargeToFullSecond
                handleCalibrationPhase(.chargeToFullSecond, currentInt: currentInt, limit: limit)
                return
            }
            operatingMode = .calibrating(.dischargeTo15)
            helper.setForceDischarge(true)
            helper.setPreventSleep(true, reason: "ChargeCap Calibration Step 2")
            lastActionSummary = "Calibration 2/5: Discharging to 15% (\(currentInt)%)"

        case .chargeToFullSecond:
            if currentInt >= 100 {
                calibrationHoldStart = Date()
                calibrationPhase = .holdAt100
                handleCalibrationPhase(.holdAt100, currentInt: currentInt, limit: limit)
                return
            }
            operatingMode = .calibrating(.chargeToFullSecond)
            helper.setForceDischarge(false)
            helper.setChargingEnabled(true)
            helper.setPreventSleep(true, reason: "ChargeCap Calibration Step 3")
            lastActionSummary = "Calibration 3/5: Recharging to 100% (\(currentInt)%)"

        case .holdAt100:
            if calibrationHoldStart == nil {
                calibrationHoldStart = Date()
            }
            if calibrationHoldRemainingSeconds <= 0 {
                calibrationPhase = .restoreToLimit
                handleCalibrationPhase(.restoreToLimit, currentInt: currentInt, limit: limit)
                return
            }
            operatingMode = .calibrating(.holdAt100)
            helper.setForceDischarge(false)
            helper.setChargingEnabled(true)
            helper.setPreventSleep(true, reason: "ChargeCap Calibration Step 4")
            let mins = calibrationHoldRemainingSeconds / 60
            lastActionSummary = "Calibration 4/5: Saturation hold at 100% (\(mins)m left)"

        case .restoreToLimit:
            if currentInt <= limit {
                calibrationPhase = nil
                calibrationHoldStart = nil
                calibrationStartedAt = nil
                sendNotification(
                    title: "Battery Calibration Finished",
                    body: "Full cycle calibration completed and battery returned to \(limit)%."
                )
                evaluateAndApply()
                return
            }
            operatingMode = .calibrating(.restoreToLimit)
            helper.setForceDischarge(true)
            helper.setPreventSleep(true, reason: "ChargeCap Calibration Step 5")
            lastActionSummary = "Calibration 5/5: Discharging back to \(limit)% (\(currentInt)%)"
        }
        syncMagSafeLED(for: operatingMode)
    }

    private func syncMagSafeLED(for mode: OperatingMode) {
        let ledPref = Prefs.shared.magSafeLEDMode
        let helper = HelperClient.shared

        switch ledPref {
        case .system:
            helper.setMagSafeLED(0x00)
        case .off:
            helper.setMagSafeLED(0x01)
        case .green:
            helper.setMagSafeLED(0x03)
        case .orange:
            helper.setMagSafeLED(0x04)
        case .auto:
            switch mode {
            case .chargingToLimit, .topUp:
                helper.setMagSafeLED(0x04) // Amber while charging
            case .calibrating(let phase):
                let isChargingPhase = (phase == .chargeToFullFirst || phase == .chargeToFullSecond)
                helper.setMagSafeLED(isChargingPhase ? 0x04 : 0x03)
            case .holdingAtLimit, .sailing, .discharging:
                helper.setMagSafeLED(0x03) // Green when capped / sailing / discharging
            case .heatProtectionPaused:
                helper.setMagSafeLED(0x02) // Slow amber pulse on thermal protection
            case .onBattery, .sleepingPaused:
                break
            }
        }
    }

    private func handlePlugTransition(previous: Bool, current: Bool) {
        if previous && !current && !snapshot.forceDischargingBySMC {
            if isTopUpActive && Prefs.shared.topUpAutoRevertOnUnplug {
                isTopUpActive = false
            }
        }
    }

    private func appendHistory(from snap: BatterySnapshot) {
        let point = TelemetryHistoryPoint(
            timestamp: snap.timestamp,
            osPercent: Double(snap.osPercentage),
            hwPercent: snap.hardwarePercentage,
            batteryWatts: snap.batteryPowerWatts,
            adapterWatts: snap.adapterInputWatts,
            systemWatts: snap.systemLoadWatts,
            temperatureC: snap.batteryTemperatureC
        )
        history.append(point)
        if history.count > 120 {
            history.removeFirst(history.count - 120)
        }
    }

    // MARK: - Sleep & Termination Lifecycle

    private func registerSleepWakeNotifications() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.handleWillSleep()
            }
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.refreshNow()
            }
        }
    }

    public func handleWillSleep() {
        let prefs = Prefs.shared
        let helper = HelperClient.shared
        if !prefs.dischargeInClamshell {
            helper.setForceDischarge(false)
        }
        if prefs.stopChargingWhenSleeping {
            helper.setChargingEnabled(false)
            operatingMode = .sleepingPaused
            lastActionSummary = "Paused charging before system sleep"
        }
    }

    public func handleAppTermination() {
        let prefs = Prefs.shared
        let helper = HelperClient.shared
        helper.setPreventSleep(false)
        helper.setForceDischarge(false)
        if prefs.stopChargingWhenPoweredOff {
            helper.setChargingEnabled(false)
        } else {
            helper.resetAllOnExit()
        }
    }

    private func sendNotification(title: String, body: String) {
        guard Prefs.shared.notificationsEnabled, !Prefs.devMode else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
