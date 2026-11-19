import Foundation
import Testing
@testable import ChargeCapCore

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func snap(
    _ pct: Int, plugged: Bool = true, charging: Bool = false, full: Bool = false,
    temp: Double = 30, hw: Double? = nil, forceDischarging: Bool = false
) -> BatterySnapshot {
    var s = BatterySnapshot.placeholder
    s.osPercentage = pct
    s.hardwarePercentage = hw ?? Double(pct)
    s.isPluggedIn = plugged
    s.isCharging = charging
    s.isFullyCharged = full
    s.batteryTemperatureC = temp
    s.forceDischargingBySMC = forceDischarging
    return s
}

private func input(
    _ s: BatterySnapshot, limit: Int = 80, sailing: Bool = false, sailLower: Int = 75,
    heat: Bool = true, heatMax: Double = 35, previous: OperatingMode = .holdingAtLimit(limit: 80),
    now: Date = t0, _ configure: (inout PolicyInput) -> Void = { _ in }
) -> PolicyInput {
    var i = PolicyInput(snapshot: s, limit: limit, sailingEnabled: sailing, sailingLowerBound: sailLower,
                        heatEnabled: heat, heatMaxC: heatMax, previousMode: previous, now: now)
    configure(&i)
    return i
}

@Suite("ChargePolicy")
struct ChargePolicyTests {

    // MARK: Limit

    @Test func chargesBelowLimit() {
        let out = ChargePolicy.evaluate(input(snap(70)))
        #expect(out.mode == .chargingToLimit(target: 80))
        #expect(out.command.chargingEnabled)
        #expect(!out.command.forceDischarge)
    }

    @Test func holdsAtLimit() {
        let out = ChargePolicy.evaluate(input(snap(80)))
        #expect(out.mode == .holdingAtLimit(limit: 80))
        #expect(!out.command.chargingEnabled)
    }

    @Test func limitReachedEventOnlyWhenWasCharging() {
        let a = ChargePolicy.evaluate(input(snap(80), previous: .chargingToLimit(target: 80)))
        #expect(a.events.contains(.limitReached(limit: 80)))
        let b = ChargePolicy.evaluate(input(snap(80), previous: .holdingAtLimit(limit: 80)))
        #expect(!b.events.contains(.limitReached(limit: 80)))
    }

    @Test func aboveLimitWithoutSailingHolds() {
        let out = ChargePolicy.evaluate(input(snap(85)))
        #expect(out.mode == .holdingAtLimit(limit: 80))
        #expect(!out.command.chargingEnabled)
    }

    // MARK: Sailing

    @Test func sailingInsideBandDoesNotCharge() {
        let out = ChargePolicy.evaluate(input(snap(77), sailing: true, previous: .holdingAtLimit(limit: 80)))
        #expect(out.mode == .sailing(lowerBound: 75, upperBound: 80))
        #expect(!out.command.chargingEnabled)
    }

    @Test func sailingBelowBandCharges() {
        let out = ChargePolicy.evaluate(input(snap(74), sailing: true))
        #expect(out.mode == .chargingToLimit(target: 80))
        #expect(out.command.chargingEnabled)
    }

    @Test func chargingContinuesThroughSailingBand() {
        let out = ChargePolicy.evaluate(input(snap(77), sailing: true, previous: .chargingToLimit(target: 80)))
        #expect(out.mode == .chargingToLimit(target: 80))
        #expect(out.command.chargingEnabled)
    }

    @Test func aboveLimitWithSailingIsSailing() {
        let out = ChargePolicy.evaluate(input(snap(82), sailing: true))
        #expect(out.mode == .sailing(lowerBound: 75, upperBound: 80))
        #expect(!out.command.chargingEnabled)
    }

    // MARK: Hardware percentage

    @Test func usesHardwarePercentageWhenEnabled() {
        let s = snap(79, hw: 81.2)
        let os = ChargePolicy.evaluate(input(s))
        #expect(os.mode == .chargingToLimit(target: 80))
        let hw = ChargePolicy.evaluate(input(s) { $0.useHardwarePercentage = true })
        #expect(hw.mode == .holdingAtLimit(limit: 80))
    }

    // MARK: Unplug

    @Test func unpluggedIsOnBatteryWithChargingEnabled() {
        let out = ChargePolicy.evaluate(input(snap(50, plugged: false)))
        #expect(out.mode == .onBattery)
        #expect(out.command.chargingEnabled)
        #expect(!out.command.forceDischarge)
        #expect(!out.command.preventSleep)
        #expect(out.command.magSafeLED == nil)
    }

    @Test func unplugCancelsManualDischarge() {
        let out = ChargePolicy.evaluate(input(snap(90, plugged: false)) { $0.manualDischargeActive = true })
        #expect(!out.manualDischargeActive)
        #expect(out.events.contains(.manualDischargeCancelled))
    }

    @Test func unplugCancelsTopUpOnlyWhenPreferred() {
        let a = ChargePolicy.evaluate(input(snap(50, plugged: false)) { $0.topUpActive = true })
        #expect(!a.topUpActive)
        #expect(a.events.contains(.topUpCancelledByUnplug))
        let b = ChargePolicy.evaluate(input(snap(50, plugged: false)) { $0.topUpActive = true; $0.topUpAutoRevertOnUnplug = false })
        #expect(b.topUpActive)
    }

    @Test func forceDischargingCountsAsPluggedIn() {
        let out = ChargePolicy.evaluate(input(snap(90, plugged: false, forceDischarging: true)) { $0.manualDischargeActive = true })
        #expect(out.mode == .discharging(target: 80, automatic: false))
        #expect(out.manualDischargeActive)
    }

    // MARK: Heat

    @Test func heatPausesAtMax() {
        let out = ChargePolicy.evaluate(input(snap(50, temp: 36)))
        if case .heatProtectionPaused = out.mode {} else { Issue.record("expected heat pause, got \(out.mode)") }
        #expect(out.heatPausedSince == t0)
        #expect(!out.command.chargingEnabled)
        #expect(out.command.magSafeLED == ChargePolicy.ledSlowBlink)
        #expect(out.events.contains(.heatPaused(tempC: 36)))
    }

    @Test func heatDoesNotResumeBeforeFiveMinutes() {
        let cool = snap(50, temp: 30)
        let early = ChargePolicy.evaluate(input(cool, now: t0.addingTimeInterval(299)) { $0.heatPausedSince = t0 })
        #expect(early.isHeatPaused)
        let late = ChargePolicy.evaluate(input(cool, now: t0.addingTimeInterval(300)) { $0.heatPausedSince = t0 })
        #expect(!late.isHeatPaused)
        #expect(late.events.contains(.heatResumed))
    }

    @Test func heatDoesNotResumeUntilTwoDegreesBelowMax() {
        let warm = snap(50, temp: 33.5)
        let out = ChargePolicy.evaluate(input(warm, now: t0.addingTimeInterval(1000)) { $0.heatPausedSince = t0 })
        #expect(out.isHeatPaused)
        let ok = ChargePolicy.evaluate(input(snap(50, temp: 33), now: t0.addingTimeInterval(1000)) { $0.heatPausedSince = t0 })
        #expect(!ok.isHeatPaused)
    }

    @Test func heatDisabledDuringCalibration() {
        let out = ChargePolicy.evaluate(input(snap(50, temp: 45)) { $0.calibrationPhase = .chargeToFullFirst })
        #expect(out.mode == .calibrating(.chargeToFullFirst))
        #expect(out.heatPausedSince == nil)
        #expect(out.command.chargingEnabled)
    }

    // MARK: Calibration

    @Test func calibrationStepOneChargesAndPreventsSleep() {
        let out = ChargePolicy.evaluate(input(snap(60)) { $0.calibrationPhase = .chargeToFullFirst })
        #expect(out.command.chargingEnabled)
        #expect(out.command.preventSleep)
    }

    @Test func calibrationAdvancesToDischargeAt100() {
        let out = ChargePolicy.evaluate(input(snap(100)) { $0.calibrationPhase = .chargeToFullFirst })
        #expect(out.mode == .calibrating(.dischargeTo10))
        #expect(out.command.forceDischarge)
        #expect(!out.command.chargingEnabled)
    }

    @Test func calibrationDischargeFloorIsTen() {
        let still = ChargePolicy.evaluate(input(snap(11)) { $0.calibrationPhase = .dischargeTo10 })
        #expect(still.mode == .calibrating(.dischargeTo10))
        let done = ChargePolicy.evaluate(input(snap(10)) { $0.calibrationPhase = .dischargeTo10 })
        #expect(done.mode == .calibrating(.chargeToFullSecond))
    }

    @Test func calibrationHoldStartsAtFull() {
        let out = ChargePolicy.evaluate(input(snap(100)) { $0.calibrationPhase = .chargeToFullSecond })
        #expect(out.mode == .calibrating(.holdAt100))
        #expect(out.calibrationHoldStart == t0)
        #expect(out.command.chargingEnabled)
    }

    @Test func calibrationHoldNeedsTenMinutesEvenIfFull() {
        let full = snap(100, charging: false, full: true)
        let early = ChargePolicy.evaluate(input(full, now: t0.addingTimeInterval(9 * 60)) {
            $0.calibrationPhase = .holdAt100; $0.calibrationHoldStart = t0
        })
        #expect(early.mode == .calibrating(.holdAt100))
        let late = ChargePolicy.evaluate(input(full, now: t0.addingTimeInterval(10 * 60)) {
            $0.calibrationPhase = .holdAt100; $0.calibrationHoldStart = t0
        })
        #expect(late.mode == .calibrating(.restoreToLimit))
        #expect(late.command.forceDischarge)
    }

    @Test func calibrationHoldContinuesWhileStillCharging() {
        let notDone = snap(100, charging: true, full: false)
        let out = ChargePolicy.evaluate(input(notDone, now: t0.addingTimeInterval(3600)) {
            $0.calibrationPhase = .holdAt100; $0.calibrationHoldStart = t0
        })
        #expect(out.mode == .calibrating(.holdAt100))
    }

    @Test func calibrationHoldEndsAfterTwoHours() {
        let notDone = snap(100, charging: true, full: false)
        let out = ChargePolicy.evaluate(input(notDone, now: t0.addingTimeInterval(2 * 3600)) {
            $0.calibrationPhase = .holdAt100; $0.calibrationHoldStart = t0
        })
        #expect(out.mode == .calibrating(.restoreToLimit))
    }

    @Test func calibrationFinishesAtLimit() {
        let out = ChargePolicy.evaluate(input(snap(80)) { $0.calibrationPhase = .restoreToLimit })
        #expect(out.calibrationPhase == nil)
        #expect(out.events.contains(.calibrationFinished))
        #expect(out.mode == .holdingAtLimit(limit: 80))
    }

    // MARK: Top up

    @Test func topUpChargesAndRevertsAt100() {
        let charging = ChargePolicy.evaluate(input(snap(90)) { $0.topUpActive = true })
        #expect(charging.mode == .topUp)
        #expect(charging.command.chargingEnabled)
        let done = ChargePolicy.evaluate(input(snap(100)) { $0.topUpActive = true })
        #expect(!done.topUpActive)
        #expect(done.events.contains(.topUpComplete))
        #expect(done.mode == .holdingAtLimit(limit: 80))
    }

    @Test func topUpStaysAt100WhenRevertDisabled() {
        let out = ChargePolicy.evaluate(input(snap(100)) { $0.topUpActive = true; $0.topUpAutoRevertAt100 = false })
        #expect(out.topUpActive)
        #expect(out.mode == .topUp)
    }

    // MARK: Discharge

    @Test func manualDischargeStopsAtLimit() {
        let going = ChargePolicy.evaluate(input(snap(90)) { $0.manualDischargeActive = true })
        #expect(going.mode == .discharging(target: 80, automatic: false))
        #expect(going.command.forceDischarge)
        #expect(!going.command.chargingEnabled)
        let done = ChargePolicy.evaluate(input(snap(80)) { $0.manualDischargeActive = true })
        #expect(!done.manualDischargeActive)
        #expect(done.events.contains(.dischargeComplete(target: 80)))
        #expect(!done.command.forceDischarge)
    }

    @Test func autoDischargeAboveLimit() {
        let out = ChargePolicy.evaluate(input(snap(92)) { $0.autoDischarge = true })
        #expect(out.mode == .discharging(target: 80, automatic: true))
    }

    @Test func lidClosedDisablesAutoDischargeUnlessClamshell() {
        let closed = ChargePolicy.evaluate(input(snap(92)) { $0.autoDischarge = true; $0.lidClosed = true })
        #expect(closed.mode == .holdingAtLimit(limit: 80))
        #expect(!closed.command.forceDischarge)
        let clamshell = ChargePolicy.evaluate(input(snap(92)) {
            $0.autoDischarge = true; $0.lidClosed = true; $0.dischargeInClamshell = true
        })
        #expect(clamshell.mode == .discharging(target: 80, automatic: true))
        #expect(clamshell.command.preventSleep)
    }

    @Test func lidClosedPausesManualDischargeToHold() {
        let out = ChargePolicy.evaluate(input(snap(90)) { $0.manualDischargeActive = true; $0.lidClosed = true })
        #expect(out.mode == .holdingAtLimit(limit: 80))
        #expect(out.manualDischargeActive)
        #expect(!out.command.forceDischarge)
    }

    @Test func forceDischargeNeverEnablesCharging() {
        let out = ChargePolicy.evaluate(input(snap(95)) { $0.manualDischargeActive = true })
        #expect(out.command.forceDischarge)
        #expect(!out.command.chargingEnabled)
    }

    // MARK: Sleep prevention

    @Test func disableSleepUntilLimitOnlyWhileCharging() {
        let charging = ChargePolicy.evaluate(input(snap(50)) { $0.disableSleepUntilLimit = true })
        #expect(charging.command.preventSleep)
        let held = ChargePolicy.evaluate(input(snap(80)) { $0.disableSleepUntilLimit = true })
        #expect(!held.command.preventSleep)
    }

    // MARK: LED

    @Test func ledAutoMapping() {
        #expect(ChargePolicy.led(for: .chargingToLimit(target: 80), mode: .auto, blink: false) == 0x04)
        #expect(ChargePolicy.led(for: .topUp, mode: .auto, blink: false) == 0x04)
        #expect(ChargePolicy.led(for: .holdingAtLimit(limit: 80), mode: .auto, blink: false) == 0x03)
        #expect(ChargePolicy.led(for: .sailing(lowerBound: 75, upperBound: 80), mode: .auto, blink: false) == 0x03)
        #expect(ChargePolicy.led(for: .discharging(target: 80, automatic: false), mode: .auto, blink: false) == 0x04)
        #expect(ChargePolicy.led(for: .discharging(target: 80, automatic: false), mode: .auto, blink: true) == 0x06)
        #expect(ChargePolicy.led(for: .heatProtectionPaused(tempC: 40, maxC: 35), mode: .auto, blink: false) == 0x06)
        #expect(ChargePolicy.led(for: .onBattery, mode: .auto, blink: false) == nil)
        #expect(ChargePolicy.led(for: .calibrating(.chargeToFullFirst), mode: .auto, blink: false) == 0x04)
        #expect(ChargePolicy.led(for: .calibrating(.restoreToLimit), mode: .auto, blink: true) == 0x06)
    }

    @Test func ledFixedModesAlwaysWrite() {
        #expect(ChargePolicy.led(for: .onBattery, mode: .system, blink: false) == 0x00)
        #expect(ChargePolicy.led(for: .onBattery, mode: .off, blink: false) == 0x01)
        #expect(ChargePolicy.led(for: .topUp, mode: .green, blink: false) == 0x03)
        #expect(ChargePolicy.led(for: .holdingAtLimit(limit: 80), mode: .orange, blink: false) == 0x04)
    }
}
