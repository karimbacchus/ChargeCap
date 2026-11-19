//
// ChargeController.swift
// ChargeCap
//
// Thin MainActor wrapper around the pure ChargePolicy: read telemetry -> build PolicyInput ->
// evaluate -> store the resulting transient state -> send the HardwareCommand to the helper.
//
// MIT License
//

import AppKit
import ChargeCapCore
import Combine
import Foundation
import UserNotifications

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
    /// Setting these from outside re-evaluates immediately (the policy may still cancel them).
    @Published public var isTopUpActive: Bool = false {
        didSet {
            guard !applyingPolicy, oldValue != isTopUpActive else { return }
            persistState()
            evaluateAndApply()
        }
    }
    @Published public var isManualDischargeActive: Bool = false {
        didSet {
            guard !applyingPolicy, oldValue != isManualDischargeActive else { return }
            persistState()
            evaluateAndApply()
        }
    }
    @Published public private(set) var calibrationPhase: CalibrationPhase? = nil
    @Published public private(set) var calibrationHoldStart: Date? = nil
    @Published public private(set) var calibrationStartedAt: Date? = nil
    @Published public private(set) var isHeatPaused: Bool = false
    /// Short in-memory history for live sparklines (persisted history lives in HistoryStore).
    @Published public private(set) var history: [TelemetryHistoryPoint] = []
    @Published public private(set) var lastActionSummary: String = "Monitoring battery telemetry"

    private static let maxLiveHistory = 180

    private var timer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var applyingPolicy = false
    private var heatPausedSince: Date?

    // Hardware re-assert bookkeeping.
    private var lastCommand: HardwareCommand?
    private var reassertPending = true
    private var lastReassert = Date.distantPast
    private var lastContradictionReassert = Date.distantPast
    private var ledRestoreOnWake = false
    private var lastClassicLimit: Int?

    private let store: UserDefaults

    public var isCalibrating: Bool {
        calibrationPhase != nil
    }

    // MARK: Calibration timing helpers

    public var calibrationHoldElapsedSeconds: Int {
        guard calibrationPhase == .holdAt100, let start = calibrationHoldStart else { return 0 }
        return max(0, Int(Date().timeIntervalSince(start)))
    }

    /// Seconds until the hold ends at the latest (the hold normally ends earlier, when the gauge reports full).
    public var calibrationHoldRemainingSeconds: Int {
        guard calibrationPhase == .holdAt100, calibrationHoldStart != nil else { return 0 }
        return max(0, Int(ChargePolicy.calibrationHoldMaximum) - calibrationHoldElapsedSeconds)
    }

    /// Seconds until the minimum hold has passed (the hold can't end before this).
    public var calibrationHoldMinimumRemainingSeconds: Int {
        guard calibrationPhase == .holdAt100, calibrationHoldStart != nil else { return 0 }
        return max(0, Int(ChargePolicy.calibrationHoldMinimum) - calibrationHoldElapsedSeconds)
    }

    public var calibrationElapsedSeconds: Int {
        guard let start = calibrationStartedAt else { return 0 }
        return max(0, Int(Date().timeIntervalSince(start)))
    }

    // MARK: - Init

    private init() {
        if Prefs.devMode, let dev = UserDefaults(suiteName: "com.chargecap.app.dev") {
            store = dev
        } else {
            store = .standard
        }
        let initial = BatteryTelemetryReader.readSnapshot()
        self.snapshot = initial
        restoreState()
        appendLiveHistory(from: initial)

        // Re-evaluate shortly after any preference change.
        Prefs.shared.objectWillChange
            .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.evaluateAndApply() }
            .store(in: &cancellables)

        // Reschedule the timer when the refresh interval changes.
        Prefs.shared.$refreshIntervalSeconds
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in self?.rescheduleTimerIfRunning() }
            }
            .store(in: &cancellables)

        // Apply the Low Power Mode policy when it changes (not every tick).
        Prefs.shared.$lowPowerModePolicy
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] policy in
                Task { @MainActor in self?.applyLowPowerPolicy(policy) }
            }
            .store(in: &cancellables)

        // Re-send everything when the helper (re)connects.
        HelperClient.shared.$isHelperConnected
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] connected in
                guard connected else { return }
                Task { @MainActor in
                    guard let self else { return }
                    self.reassertPending = true
                    self.evaluateAndApply()
                    self.applyLowPowerPolicy(Prefs.shared.lowPowerModePolicy)
                }
            }
            .store(in: &cancellables)

        registerSleepWakeNotifications()
    }

    // MARK: - Monitoring

    public func startMonitoring() {
        if !Prefs.devMode {
            HelperClient.shared.checkHelperStatus()
            requestNotificationAuthorization()
            if Prefs.shared.lowPowerModePolicy != .unmanaged {
                applyLowPowerPolicy(Prefs.shared.lowPowerModePolicy)
            }
        }
        HistoryStore.shared.recordHealth(snapshot: snapshot)
        refreshNow()
        rescheduleTimer()
    }

    private func rescheduleTimerIfRunning() {
        if timer != nil { rescheduleTimer() }
    }

    private func rescheduleTimer() {
        timer?.invalidate()
        let interval = TimeInterval(min(20, max(2, Prefs.shared.refreshIntervalSeconds)))
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshNow() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func refreshNow() {
        let latest = BatteryTelemetryReader.readSnapshot()
        self.snapshot = latest
        appendLiveHistory(from: latest)
        HistoryStore.shared.record(snapshot: latest, limit: Prefs.shared.chargeLimit)
        evaluateAndApply()
    }

    /// Evaluates the policy against a caller-supplied snapshot (tests / previews).
    public func evaluateWithSnapshot(_ customSnapshot: BatterySnapshot) {
        self.snapshot = customSnapshot
        evaluateAndApply()
    }

    // MARK: - User actions

    public func setTopUp(_ enabled: Bool) {
        mutateState {
            if enabled {
                isManualDischargeActive = false
                clearCalibration()
            }
            isTopUpActive = enabled
        }
    }

    public func setManualDischarge(_ enabled: Bool) {
        mutateState {
            if enabled {
                isTopUpActive = false
                clearCalibration()
            }
            isManualDischargeActive = enabled
        }
    }

    public func toggleTopUp() { setTopUp(!isTopUpActive) }

    public func toggleManualDischarge() { setManualDischarge(!isManualDischargeActive) }

    public func startCalibration() {
        mutateState {
            isTopUpActive = false
            isManualDischargeActive = false
            calibrationStartedAt = Date()
            calibrationHoldStart = nil
            calibrationPhase = .chargeToFullFirst
        }
    }

    public func advanceCalibrationStep() {
        guard let phase = calibrationPhase else { return }
        mutateState {
            if let next = phase.next {
                calibrationPhase = next
                calibrationHoldStart = (next == .holdAt100) ? Date() : nil
            } else {
                clearCalibration()
            }
        }
    }

    public func stopCalibration() {
        mutateState { clearCalibration() }
    }

    public func setChargeLimit(_ newLimit: Int) {
        Prefs.shared.chargeLimit = newLimit
        evaluateAndApply()
    }

    private func clearCalibration() {
        calibrationPhase = nil
        calibrationHoldStart = nil
        calibrationStartedAt = nil
    }

    /// Mutates transient state without per-property re-evaluation, then evaluates once.
    private func mutateState(_ block: () -> Void) {
        applyingPolicy = true
        block()
        applyingPolicy = false
        persistState()
        evaluateAndApply()
    }

    // MARK: - Core evaluation

    /// Runs the policy and sends the resulting command. `force` re-sends all hardware state.
    public func evaluateAndApply(force: Bool = false) {
        let prefs = Prefs.shared
        let now = Date()

        let input = PolicyInput(
            snapshot: snapshot,
            limit: prefs.chargeLimit,
            sailingEnabled: prefs.sailingModeEnabled,
            sailingLowerBound: prefs.sailingTarget,
            heatEnabled: prefs.heatProtectionEnabled,
            heatMaxC: prefs.heatProtectionMaxCelsius,
            autoDischarge: prefs.autoDischargeEnabled,
            dischargeInClamshell: prefs.dischargeInClamshell,
            lidClosed: snapshot.lidClosed,
            topUpActive: isTopUpActive,
            manualDischargeActive: isManualDischargeActive,
            calibrationPhase: calibrationPhase,
            calibrationHoldStart: calibrationHoldStart,
            heatPausedSince: heatPausedSince,
            useHardwarePercentage: prefs.useHardwarePercentage,
            disableSleepUntilLimit: prefs.disableSleepUntilChargeLimit,
            ledMode: prefs.magSafeLEDMode,
            ledBlinkWhileDischarging: prefs.ledBlinkWhileDischarging,
            topUpAutoRevertAt100: prefs.topUpAutoRevertAt100,
            topUpAutoRevertOnUnplug: prefs.topUpAutoRevertOnUnplug,
            previousMode: operatingMode,
            now: now
        )
        let out = ChargePolicy.evaluate(input)

        // Store the new transient state.
        applyingPolicy = true
        if isTopUpActive != out.topUpActive { isTopUpActive = out.topUpActive }
        if isManualDischargeActive != out.manualDischargeActive { isManualDischargeActive = out.manualDischargeActive }
        if calibrationPhase != out.calibrationPhase { calibrationPhase = out.calibrationPhase }
        if calibrationHoldStart != out.calibrationHoldStart { calibrationHoldStart = out.calibrationHoldStart }
        if out.calibrationPhase == nil && calibrationStartedAt != nil { calibrationStartedAt = nil }
        if isHeatPaused != out.isHeatPaused { isHeatPaused = out.isHeatPaused }
        if operatingMode != out.mode { operatingMode = out.mode }
        if lastActionSummary != out.summary { lastActionSummary = out.summary }
        applyingPolicy = false
        heatPausedSince = out.heatPausedSince
        let stateChanged = !out.events.isEmpty
        if stateChanged { persistState() }

        for event in out.events { handle(event, prefs: prefs) }

        // Hardware.
        var command = out.command
        var reassert = force || reassertPending
        if now.timeIntervalSince(lastReassert) >= 60 { reassert = true }
        if let prev = lastCommand, now.timeIntervalSince(lastContradictionReassert) >= 15, contradicts(prev) {
            reassert = true
            lastContradictionReassert = now
        }
        if ledRestoreOnWake {
            if command.magSafeLED == nil { command.magSafeLED = ChargePolicy.ledSystem }
            ledRestoreOnWake = false
            reassert = true
        }
        if reassert {
            lastReassert = now
            reassertPending = false
        }
        lastCommand = out.command
        HelperClient.shared.apply(command, force: reassert)

        if prefs.useClassicIntelKey, lastClassicLimit != prefs.chargeLimit {
            lastClassicLimit = prefs.chargeLimit
            HelperClient.shared.setClassicMaxCharge(UInt8(clamping: prefs.chargeLimit))
        }

        SleepControl.shared.evaluate(batteryPercent: snapshot.osPercentage, isPluggedIn: snapshot.isPluggedIn)
    }

    /// True when telemetry shows the hardware isn't doing what the previous command asked.
    private func contradicts(_ prev: HardwareCommand) -> Bool {
        if !prev.chargingEnabled && !prev.forceDischarge
            && snapshot.isCharging && snapshot.isPluggedIn && !snapshot.forceDischargingBySMC {
            return true
        }
        if prev.forceDischarge && snapshot.isPluggedIn && !snapshot.forceDischargingBySMC {
            return true
        }
        return false
    }

    // MARK: - Events -> notifications

    private func handle(_ event: PolicyEvent, prefs: Prefs) {
        switch event {
        case .limitReached(let limit):
            if prefs.notifyLimitReached {
                postNotification(title: "Charge Limit Reached (\(limit)%)", body: "MacBook is now powered directly by the adapter.")
            }
        case .topUpComplete:
            if prefs.notifyTopUp {
                postNotification(title: "Top Up Complete", body: "Battery reached 100%. Returning to \(prefs.chargeLimit)% charge limit.")
            }
        case .topUpCancelledByUnplug:
            break
        case .dischargeComplete(let target):
            if prefs.notifyDischarge {
                postNotification(title: "Discharge Complete", body: "Battery discharged to target \(target)%.")
            }
        case .manualDischargeCancelled:
            break
        case .heatPaused(let tempC):
            if prefs.notifyHeat {
                postNotification(title: "Heat Protection Activated",
                                 body: "Battery reached \(prefs.formatTemperature(tempC)). Charging paused until it cools down.")
            }
        case .heatResumed:
            if prefs.notifyHeat, prefs.heatProtectionEnabled {
                postNotification(title: "Heat Protection Ended", body: "Battery has cooled down. Charging can resume.")
            }
        case .calibrationAdvanced(let phase):
            if prefs.notifyCalibration {
                postNotification(title: "Calibration", body: phase.title)
            }
        case .calibrationFinished:
            if prefs.notifyCalibration {
                postNotification(title: "Battery Calibration Finished",
                                 body: "Full cycle calibration completed and battery returned to \(prefs.chargeLimit)%.")
            }
        }
    }

    private var canUseNotifications: Bool {
        !Prefs.devMode && Bundle.main.bundleIdentifier != nil
    }

    private func requestNotificationAuthorization() {
        guard canUseNotifications else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Posts a user notification if notifications are enabled (also used by the scheduler).
    public func postNotification(title: String, body: String) {
        guard Prefs.shared.notificationsEnabled, canUseNotifications else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    // MARK: - Low Power Mode policy

    private func applyLowPowerPolicy(_ policy: LowPowerModePolicy) {
        guard !Prefs.devMode, let desired = policy.desiredState else { return }
        HelperClient.shared.setLowPowerMode(desired.battery, scope: .battery)
        HelperClient.shared.setLowPowerMode(desired.adapter, scope: .adapter)
    }

    // MARK: - Persistence of transient state

    private enum Key {
        static let topUp = "state.topUpActive"
        static let discharge = "state.manualDischargeActive"
        static let phase = "state.calibrationPhase"
        static let holdStart = "state.calibrationHoldStart"
        static let startedAt = "state.calibrationStartedAt"
    }

    private func persistState() {
        store.set(isTopUpActive, forKey: Key.topUp)
        store.set(isManualDischargeActive, forKey: Key.discharge)
        if let phase = calibrationPhase {
            store.set(phase.rawValue, forKey: Key.phase)
        } else {
            store.removeObject(forKey: Key.phase)
        }
        if let d = calibrationHoldStart { store.set(d, forKey: Key.holdStart) } else { store.removeObject(forKey: Key.holdStart) }
        if let d = calibrationStartedAt { store.set(d, forKey: Key.startedAt) } else { store.removeObject(forKey: Key.startedAt) }
    }

    private func restoreState() {
        applyingPolicy = true
        isTopUpActive = store.bool(forKey: Key.topUp)
        isManualDischargeActive = store.bool(forKey: Key.discharge)
        if store.object(forKey: Key.phase) != nil {
            calibrationPhase = CalibrationPhase(rawValue: store.integer(forKey: Key.phase))
        }
        if calibrationPhase != nil {
            calibrationHoldStart = store.object(forKey: Key.holdStart) as? Date
            calibrationStartedAt = store.object(forKey: Key.startedAt) as? Date
        }
        applyingPolicy = false
    }

    // MARK: - Live history

    private func appendLiveHistory(from snap: BatterySnapshot) {
        history.append(TelemetryHistoryPoint(
            timestamp: snap.timestamp,
            osPercent: Double(snap.osPercentage),
            hwPercent: snap.hardwarePercentage,
            batteryWatts: snap.batteryPowerWatts,
            adapterWatts: snap.adapterInputWatts,
            systemWatts: snap.systemLoadWatts,
            temperatureC: snap.batteryTemperatureC
        ))
        if history.count > Self.maxLiveHistory {
            history.removeFirst(history.count - Self.maxLiveHistory)
        }
    }

    // MARK: - Sleep & termination lifecycle

    private func registerSleepWakeNotifications() {
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleWillSleep() }
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.handleDidWake() }
        }
    }

    public func handleWillSleep() {
        let prefs = Prefs.shared
        var cmd = lastCommand ?? HardwareCommand(chargingEnabled: true, forceDischarge: false, magSafeLED: nil, preventSleep: false)
        cmd.magSafeLED = nil
        if !prefs.dischargeInClamshell {
            cmd.forceDischarge = false
        }
        if prefs.stopChargingWhenSleeping {
            cmd.chargingEnabled = false
            operatingMode = .sleepingPaused
            lastActionSummary = "Paused charging before system sleep"
        }
        if cmd.forceDischarge { cmd.chargingEnabled = false }
        if prefs.ledOffDuringSleep {
            cmd.magSafeLED = ChargePolicy.ledOff
            ledRestoreOnWake = true
        }
        HelperClient.shared.apply(cmd)
    }

    public func handleDidWake() {
        reassertPending = true
        refreshNow()
    }

    public func handleAppTermination() {
        timer?.invalidate()
        timer = nil
        persistState()
        HistoryStore.shared.flush(wait: true)
        HelperClient.shared.restoreOnQuit(keepChargeInhibited: Prefs.shared.stopChargingWhenAppClosed)
    }
}
