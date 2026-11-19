//
// ChargePolicy.swift
// ChargeCapCore
//
// Pure, hardware-free charge policy. Given a telemetry snapshot, the user's settings and the
// transient state (top up, discharge, calibration, heat pause) it decides what the hardware
// should do and how the transient state evolves. No SMC, no XPC, no clocks: `now` is an input.
//
// MIT License
//

import Foundation

// MARK: - Calibration

public enum CalibrationPhase: Int, CaseIterable, Codable, Sendable, Identifiable {
    case chargeToFullFirst = 1
    case dischargeTo10 = 2
    case chargeToFullSecond = 3
    case holdAt100 = 4
    case restoreToLimit = 5

    public var id: Int { rawValue }

    public var title: String {
        switch self {
        case .chargeToFullFirst: return "Step 1/5 · Charge to 100%"
        case .dischargeTo10: return "Step 2/5 · Discharge to 10%"
        case .chargeToFullSecond: return "Step 3/5 · Recharge to 100%"
        case .holdAt100: return "Step 4/5 · Hold at 100%"
        case .restoreToLimit: return "Step 5/5 · Restore to Limit"
        }
    }

    public var shortTitle: String {
        switch self {
        case .chargeToFullFirst: return "Charging → 100%"
        case .dischargeTo10: return "Discharging → 10%"
        case .chargeToFullSecond: return "Recharging → 100%"
        case .holdAt100: return "Holding 100%"
        case .restoreToLimit: return "Restoring Limit"
        }
    }

    /// The phase after this one, or nil when calibration is finished.
    public var next: CalibrationPhase? {
        CalibrationPhase(rawValue: rawValue + 1)
    }
}

// MARK: - Operating mode

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

// MARK: - Events

public enum PolicyEvent: Equatable, Sendable {
    case limitReached(limit: Int)
    case topUpComplete
    case topUpCancelledByUnplug
    case dischargeComplete(target: Int)
    case manualDischargeCancelled
    case heatPaused(tempC: Double)
    case heatResumed
    case calibrationAdvanced(CalibrationPhase)
    case calibrationFinished
}

// MARK: - Input / output

public struct PolicyInput {
    public var snapshot: BatterySnapshot
    public var limit: Int
    public var sailingEnabled: Bool
    public var sailingLowerBound: Int
    public var heatEnabled: Bool
    public var heatMaxC: Double
    public var autoDischarge: Bool
    public var dischargeInClamshell: Bool
    public var lidClosed: Bool
    public var topUpActive: Bool
    public var manualDischargeActive: Bool
    public var calibrationPhase: CalibrationPhase?
    public var calibrationHoldStart: Date?
    public var heatPausedSince: Date?
    public var useHardwarePercentage: Bool
    public var disableSleepUntilLimit: Bool
    public var ledMode: MagSafeLEDMode
    public var ledBlinkWhileDischarging: Bool
    public var topUpAutoRevertAt100: Bool
    public var topUpAutoRevertOnUnplug: Bool
    public var previousMode: OperatingMode
    public var now: Date

    public init(
        snapshot: BatterySnapshot,
        limit: Int = 80,
        sailingEnabled: Bool = false,
        sailingLowerBound: Int = 75,
        heatEnabled: Bool = true,
        heatMaxC: Double = 35,
        autoDischarge: Bool = false,
        dischargeInClamshell: Bool = false,
        lidClosed: Bool = false,
        topUpActive: Bool = false,
        manualDischargeActive: Bool = false,
        calibrationPhase: CalibrationPhase? = nil,
        calibrationHoldStart: Date? = nil,
        heatPausedSince: Date? = nil,
        useHardwarePercentage: Bool = false,
        disableSleepUntilLimit: Bool = false,
        ledMode: MagSafeLEDMode = .auto,
        ledBlinkWhileDischarging: Bool = false,
        topUpAutoRevertAt100: Bool = true,
        topUpAutoRevertOnUnplug: Bool = true,
        previousMode: OperatingMode = .holdingAtLimit(limit: 80),
        now: Date = Date()
    ) {
        self.snapshot = snapshot
        self.limit = limit
        self.sailingEnabled = sailingEnabled
        self.sailingLowerBound = sailingLowerBound
        self.heatEnabled = heatEnabled
        self.heatMaxC = heatMaxC
        self.autoDischarge = autoDischarge
        self.dischargeInClamshell = dischargeInClamshell
        self.lidClosed = lidClosed
        self.topUpActive = topUpActive
        self.manualDischargeActive = manualDischargeActive
        self.calibrationPhase = calibrationPhase
        self.calibrationHoldStart = calibrationHoldStart
        self.heatPausedSince = heatPausedSince
        self.useHardwarePercentage = useHardwarePercentage
        self.disableSleepUntilLimit = disableSleepUntilLimit
        self.ledMode = ledMode
        self.ledBlinkWhileDischarging = ledBlinkWhileDischarging
        self.topUpAutoRevertAt100 = topUpAutoRevertAt100
        self.topUpAutoRevertOnUnplug = topUpAutoRevertOnUnplug
        self.previousMode = previousMode
        self.now = now
    }
}

public struct PolicyOutput {
    public var mode: OperatingMode
    public var command: HardwareCommand
    public var events: [PolicyEvent]
    public var summary: String

    // Updated transient state: the controller just stores these.
    public var topUpActive: Bool
    public var manualDischargeActive: Bool
    public var calibrationPhase: CalibrationPhase?
    public var calibrationHoldStart: Date?
    public var heatPausedSince: Date?

    public var isHeatPaused: Bool { heatPausedSince != nil }
}

// MARK: - Policy

public enum ChargePolicy {
    /// Minimum time the heat pause is held before charging may resume.
    public static let heatMinimumPause: TimeInterval = 5 * 60
    /// Degrees below the maximum the battery must cool before charging resumes.
    public static let heatHysteresisC: Double = 2
    public static let calibrationHoldMinimum: TimeInterval = 10 * 60
    public static let calibrationHoldMaximum: TimeInterval = 2 * 60 * 60
    public static let calibrationDischargeFloor = 10

    // MagSafe LED bytes (ACLC).
    public static let ledSystem: UInt8 = 0x00
    public static let ledOff: UInt8 = 0x01
    public static let ledGreen: UInt8 = 0x03
    public static let ledAmber: UInt8 = 0x04
    public static let ledSlowBlink: UInt8 = 0x06

    public static func evaluate(_ input: PolicyInput) -> PolicyOutput {
        let snap = input.snapshot
        let limit = input.limit
        let level = Int(snap.percentage(useHardware: input.useHardwarePercentage).rounded())
        let now = input.now

        var topUp = input.topUpActive
        var manual = input.manualDischargeActive
        var phase = input.calibrationPhase
        var holdStart = input.calibrationHoldStart
        var heatSince = input.heatPausedSince
        var events: [PolicyEvent] = []

        func output(_ mode: OperatingMode, charging: Bool, discharge: Bool, sleep: Bool, reason: String, _ summary: String) -> PolicyOutput {
            let cmd = HardwareCommand(
                chargingEnabled: discharge ? false : charging,
                forceDischarge: discharge,
                magSafeLED: led(for: mode, mode: input.ledMode, blink: input.ledBlinkWhileDischarging),
                preventSleep: sleep,
                preventSleepReason: reason
            )
            return PolicyOutput(
                mode: mode, command: cmd, events: events, summary: summary,
                topUpActive: topUp, manualDischargeActive: manual,
                calibrationPhase: phase, calibrationHoldStart: holdStart, heatPausedSince: heatSince
            )
        }

        // 1. Unplugged (and not force-discharging): nothing to control, cancel transient requests.
        if !snap.isPluggedIn && !snap.forceDischargingBySMC {
            if manual {
                manual = false
                events.append(.manualDischargeCancelled)
            }
            if topUp && input.topUpAutoRevertOnUnplug {
                topUp = false
                events.append(.topUpCancelledByUnplug)
            }
            return output(.onBattery, charging: true, discharge: false, sleep: false,
                          reason: "ChargeCap", "On battery power (\(level)%)")
        }

        // 2. Heat protection (never during calibration) with 2 °C and 5 minute hysteresis.
        if input.heatEnabled && phase == nil {
            if let since = heatSince {
                if snap.batteryTemperatureC <= input.heatMaxC - heatHysteresisC
                    && now.timeIntervalSince(since) >= heatMinimumPause {
                    heatSince = nil
                    events.append(.heatResumed)
                }
            } else if snap.batteryTemperatureC >= input.heatMaxC {
                heatSince = now
                events.append(.heatPaused(tempC: snap.batteryTemperatureC))
            }
        } else if heatSince != nil {
            heatSince = nil
            events.append(.heatResumed)
        }

        if heatSince != nil {
            return output(.heatProtectionPaused(tempC: snap.batteryTemperatureC, maxC: input.heatMaxC),
                          charging: false, discharge: false, sleep: false, reason: "ChargeCap",
                          "Charging paused by Heat Protection (\(String(format: "%.1f", snap.batteryTemperatureC))°C)")
        }

        // 3. Calibration state machine.
        if phase != nil {
            var steps = 0
            while let current = phase, steps < 6 {
                steps += 1
                var advance = false
                switch current {
                case .chargeToFullFirst:
                    advance = level >= 100
                case .dischargeTo10:
                    advance = level <= calibrationDischargeFloor
                case .chargeToFullSecond:
                    advance = level >= 100
                case .holdAt100:
                    if holdStart == nil { holdStart = now }
                    let elapsed = now.timeIntervalSince(holdStart ?? now)
                    let settled = snap.isFullyCharged && !snap.isCharging && elapsed >= calibrationHoldMinimum
                    advance = settled || elapsed >= calibrationHoldMaximum
                case .restoreToLimit:
                    advance = level <= limit
                }
                guard advance else { break }
                if let next = current.next {
                    phase = next
                    if next == .holdAt100 { holdStart = now }
                    events.append(.calibrationAdvanced(next))
                } else {
                    phase = nil
                }
                if current == .restoreToLimit {
                    phase = nil
                    holdStart = nil
                    events.append(.calibrationFinished)
                }
            }

            if let current = phase {
                let mode = OperatingMode.calibrating(current)
                switch current {
                case .chargeToFullFirst, .chargeToFullSecond:
                    return output(mode, charging: true, discharge: false, sleep: true,
                                  reason: "ChargeCap Calibration", "Calibration \(current.rawValue)/5: Charging to 100% (\(level)%)")
                case .dischargeTo10:
                    return output(mode, charging: false, discharge: true, sleep: true,
                                  reason: "ChargeCap Calibration", "Calibration 2/5: Discharging to 10% (\(level)%)")
                case .holdAt100:
                    let elapsed = Int(now.timeIntervalSince(holdStart ?? now))
                    let minsLeft = max(0, Int(calibrationHoldMaximum) - elapsed) / 60
                    return output(mode, charging: true, discharge: false, sleep: true,
                                  reason: "ChargeCap Calibration", "Calibration 4/5: Holding at 100% until the gauge reports full (max \(minsLeft)m left)")
                case .restoreToLimit:
                    return output(mode, charging: false, discharge: true, sleep: true,
                                  reason: "ChargeCap Calibration", "Calibration 5/5: Discharging back to \(limit)% (\(level)%)")
                }
            }
            // Calibration just finished: fall through to normal behaviour this tick.
            holdStart = nil
        }

        // 4. Top Up (charge to 100%).
        if topUp {
            if level >= 100 && input.topUpAutoRevertAt100 {
                topUp = false
                events.append(.topUpComplete)
            } else {
                return output(.topUp, charging: true, discharge: false, sleep: input.disableSleepUntilLimit,
                              reason: "ChargeCap Top Up", "Topping up battery to 100% (currently \(level)%)")
            }
        }

        // 5. Manual / automatic discharge toward the limit.
        let autoDischarge = input.autoDischarge && level > limit
            && (!input.lidClosed || input.dischargeInClamshell)
        if manual || autoDischarge {
            if level <= limit {
                if manual {
                    manual = false
                    events.append(.dischargeComplete(target: limit))
                }
                return output(.holdingAtLimit(limit: limit), charging: false, discharge: false, sleep: false,
                              reason: "ChargeCap", "Reached \(limit)% limit · Holding on adapter power")
            }
            if manual && input.lidClosed && !input.dischargeInClamshell {
                return output(.holdingAtLimit(limit: limit), charging: false, discharge: false, sleep: false,
                              reason: "ChargeCap", "Discharge paused while the lid is closed (holding at \(level)%)")
            }
            return output(.discharging(target: limit, automatic: !manual), charging: false, discharge: true,
                          sleep: input.dischargeInClamshell, reason: "ChargeCap Active Discharge",
                          "Actively discharging to \(limit)% (currently \(level)%)")
        }

        // 6. Standard charge limit + sailing.
        let sailLower = input.sailingEnabled ? min(limit, input.sailingLowerBound) : limit
        var wasCharging = false
        if case .chargingToLimit = input.previousMode { wasCharging = true }

        if level < sailLower {
            return output(.chargingToLimit(target: limit), charging: true, discharge: false,
                          sleep: input.disableSleepUntilLimit, reason: "ChargeCap Charging to Limit",
                          "Charging toward \(limit)% limit")
        }
        if level >= limit {
            if wasCharging { events.append(.limitReached(limit: limit)) }
            if input.sailingEnabled && level > limit {
                return output(.sailing(lowerBound: sailLower, upperBound: limit), charging: false, discharge: false,
                              sleep: false, reason: "ChargeCap", "Above \(limit)% · Sailing active (\(sailLower)–\(limit)%)")
            }
            return output(.holdingAtLimit(limit: limit), charging: false, discharge: false, sleep: false,
                          reason: "ChargeCap", "Holding battery at \(limit)% on adapter power")
        }
        // Inside the sailing band: keep charging through it if we were already charging.
        if wasCharging {
            return output(.chargingToLimit(target: limit), charging: true, discharge: false,
                          sleep: input.disableSleepUntilLimit, reason: "ChargeCap Charging to Limit",
                          "Charging through sailing band to \(limit)%")
        }
        return output(.sailing(lowerBound: sailLower, upperBound: limit), charging: false, discharge: false,
                      sleep: false, reason: "ChargeCap",
                      "Sailing between \(sailLower)% and \(limit)% (no micro-charging)")
    }

    // MARK: LED

    /// ACLC byte for a mode, or nil to leave the LED alone.
    public static func led(for operating: OperatingMode, mode: MagSafeLEDMode, blink: Bool) -> UInt8? {
        switch mode {
        case .system: return ledSystem
        case .off: return ledOff
        case .green: return ledGreen
        case .orange: return ledAmber
        case .auto:
            let discharging: UInt8 = blink ? ledSlowBlink : ledAmber
            switch operating {
            case .chargingToLimit, .topUp: return ledAmber
            case .holdingAtLimit, .sailing: return ledGreen
            case .discharging: return discharging
            case .calibrating(let phase):
                switch phase {
                case .chargeToFullFirst, .chargeToFullSecond: return ledAmber
                case .holdAt100: return ledGreen
                case .dischargeTo10, .restoreToLimit: return discharging
                }
            case .heatProtectionPaused: return ledSlowBlink
            case .onBattery, .sleepingPaused: return nil
            }
        }
    }
}
