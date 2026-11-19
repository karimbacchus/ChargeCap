//
// ShortcutsIntents.swift
// ChargeCap
//
// MIT License
//

import AppIntents
import ChargeCapCore
import Foundation

public struct SetChargeLimitIntent: AppIntent {
    public static let title: LocalizedStringResource = "Set Battery Charge Limit"
    public static let description = IntentDescription("Sets ChargeCap's maximum battery charge percentage.")

    @Parameter(title: "Charge Limit (%)", default: 80, inclusiveRange: (10, 100))
    public var limit: Int

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let clamped = min(100, max(10, limit))
        if clamped < 20 {
            Prefs.shared.allowLowLimits = true
        }
        ChargeController.shared.setChargeLimit(clamped)
        return .result(dialog: "ChargeCap charge limit set to \(clamped)%.")
    }
}

public struct TopUpBatteryIntent: AppIntent {
    public static let title: LocalizedStringResource = "Top Up Battery to 100%"
    public static let description = IntentDescription("Temporarily overrides the charge limit to charge to 100%.")

    @Parameter(title: "Enable Top Up", default: true)
    public var enable: Bool

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        ChargeController.shared.isTopUpActive = enable
        return .result(dialog: enable ? "Top Up to 100% started." : "Top Up stopped.")
    }
}

public struct ToggleDischargeIntent: AppIntent {
    public static let title: LocalizedStringResource = "Discharge Battery to Limit"
    public static let description = IntentDescription("Runs the MacBook on battery power even while plugged in until the charge limit is reached.")

    @Parameter(title: "Enable Discharge", default: true)
    public var enable: Bool

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        ChargeController.shared.isManualDischargeActive = enable
        let limit = Prefs.shared.chargeLimit
        return .result(dialog: enable ? "Discharging battery to \(limit)%." : "Active discharge stopped.")
    }
}

public struct StartCalibrationIntent: AppIntent {
    public static let title: LocalizedStringResource = "Control Battery Calibration Mode"
    public static let description = IntentDescription("Starts or stops ChargeCap's 5-step Battery Calibration Mode.")

    @Parameter(title: "Run Calibration", default: true)
    public var start: Bool

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        if start {
            ChargeController.shared.startCalibration()
            return .result(dialog: "Started 5-step Battery Calibration Mode.")
        } else {
            ChargeController.shared.stopCalibration()
            return .result(dialog: "Stopped Battery Calibration Mode.")
        }
    }
}

public struct ToggleSailingModeIntent: AppIntent {
    public static let title: LocalizedStringResource = "Configure Sailing Mode"
    public static let description = IntentDescription("Enables or disables Sailing Mode and sets the sailing buffer percentage.")

    @Parameter(title: "Enable Sailing Mode", default: true)
    public var enable: Bool

    @Parameter(title: "Sailing Difference (%)", default: 5, inclusiveRange: (1, 30))
    public var delta: Int

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        Prefs.shared.sailingModeEnabled = enable
        Prefs.shared.sailingDelta = delta
        ChargeController.shared.evaluateAndApply()
        return .result(dialog: enable ? "Sailing Mode enabled (\(Prefs.shared.sailingTarget)–\(Prefs.shared.chargeLimit)%)." : "Sailing Mode disabled.")
    }
}

public struct GetBatteryStatusIntent: AppIntent {
    public static let title: LocalizedStringResource = "Get Battery & Power Flow Status"
    public static let description = IntentDescription("Returns live battery percentage, hardware BMS percentage, temperature, and wattage.")

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        ChargeController.shared.refreshNow()
        let snap = ChargeController.shared.snapshot
        let mode = ChargeController.shared.operatingMode.badgeText
        let summary = String(
            format: "Battery: %d%% (Hardware: %.1f%%) · %@ · Temp: %.1f°C · Adapter: %.1fW · System: %.1fW · Health: %.1f%% (%d cycles)",
            snap.osPercentage,
            snap.hardwarePercentage,
            mode,
            snap.batteryTemperatureC,
            snap.adapterInputWatts,
            snap.systemLoadWatts,
            snap.healthPercentage,
            snap.cycleCount
        )
        return .result(value: summary, dialog: IntentDialog(stringLiteral: summary))
    }
}

// MARK: - Shared enums

public enum ChargingStateOption: String, AppEnum {
    case charging, paused, discharging, sailing, topUp, calibrating, heatPaused, onBattery

    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Charging State"
    public static let caseDisplayRepresentations: [ChargingStateOption: DisplayRepresentation] = [
        .charging: "Charging",
        .paused: "Paused (at limit)",
        .discharging: "Discharging",
        .sailing: "Sailing",
        .topUp: "Top Up",
        .calibrating: "Calibrating",
        .heatPaused: "Paused (heat protection)",
        .onBattery: "On Battery"
    ]

    @MainActor
    static func current() -> ChargingStateOption {
        switch ChargeController.shared.operatingMode {
        case .chargingToLimit: return .charging
        case .holdingAtLimit, .sleepingPaused: return .paused
        case .sailing: return .sailing
        case .discharging: return .discharging
        case .topUp: return .topUp
        case .calibrating: return .calibrating
        case .heatProtectionPaused: return .heatPaused
        case .onBattery: return .onBattery
        }
    }
}

public enum MagSafeLEDOption: String, AppEnum {
    case auto, green, orange, off, system

    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "MagSafe LED Mode"
    public static let caseDisplayRepresentations: [MagSafeLEDOption: DisplayRepresentation] = [
        .auto: "Sync with ChargeCap",
        .green: "Always Green",
        .orange: "Always Amber",
        .off: "Off (Stealth)",
        .system: "macOS Default"
    ]

    var mode: MagSafeLEDMode { MagSafeLEDMode(rawValue: rawValue) ?? .auto }
}

public enum LowPowerModeOption: String, AppEnum {
    case unmanaged, alwaysOff, alwaysOn, onlyOnBattery, onlyOnAdapter

    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Low Power Mode"
    public static let caseDisplayRepresentations: [LowPowerModeOption: DisplayRepresentation] = [
        .unmanaged: "Managed by macOS",
        .alwaysOff: "Always Off",
        .alwaysOn: "Always On",
        .onlyOnBattery: "Only on Battery",
        .onlyOnAdapter: "Only on Power Adapter"
    ]

    var policy: LowPowerModePolicy { LowPowerModePolicy(rawValue: rawValue) ?? .unmanaged }
}

public enum SleepControlOption: String, AppEnum {
    case minutes30, hour1, hours2, hours5, indefinitely

    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Sleep Control Duration"
    public static let caseDisplayRepresentations: [SleepControlOption: DisplayRepresentation] = [
        .minutes30: "30 minutes",
        .hour1: "1 hour",
        .hours2: "2 hours",
        .hours5: "5 hours",
        .indefinitely: "Indefinitely"
    ]

    var duration: SleepControlDuration {
        switch self {
        case .minutes30: return .minutes30
        case .hour1: return .hour1
        case .hours2: return .hours2
        case .hours5: return .hours5
        case .indefinitely: return .indefinitely
        }
    }
}

// MARK: - Read-only queries

public struct GetBatteryPercentageIntent: AppIntent {
    public static let title: LocalizedStringResource = "Get Battery Percentage"
    public static let description = IntentDescription("Returns the current battery percentage, optionally the more precise hardware (BMS) value.")

    @Parameter(title: "Use Hardware Percentage", default: false)
    public var hardware: Bool

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        ChargeController.shared.refreshNow()
        let snap = ChargeController.shared.snapshot
        let value = hardware ? Int(snap.hardwarePercentage.rounded()) : snap.osPercentage
        return .result(value: value, dialog: "Battery is at \(value)%.")
    }
}

public struct GetChargeLimitIntent: AppIntent {
    public static let title: LocalizedStringResource = "Get Charge Limit"
    public static let description = IntentDescription("Returns ChargeCap's current maximum charge percentage.")

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let limit = Prefs.shared.chargeLimit
        return .result(value: limit, dialog: "Charge limit is \(limit)%.")
    }
}

public struct GetChargingStateIntent: AppIntent {
    public static let title: LocalizedStringResource = "Get Charging State"
    public static let description = IntentDescription("Returns what ChargeCap is doing: charging, paused, discharging, sailing, top up, calibrating, heat paused or on battery.")

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<ChargingStateOption> & ProvidesDialog {
        ChargeController.shared.refreshNow()
        let state = ChargingStateOption.current()
        let text = ChargeController.shared.operatingMode.badgeText
        return .result(value: state, dialog: IntentDialog(stringLiteral: text))
    }
}

public struct GetBatteryTemperatureIntent: AppIntent {
    public static let title: LocalizedStringResource = "Get Battery Temperature"
    public static let description = IntentDescription("Returns the battery temperature in degrees Celsius.")

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ReturnsValue<Double> & ProvidesDialog {
        ChargeController.shared.refreshNow()
        let t = (ChargeController.shared.snapshot.batteryTemperatureC * 10).rounded() / 10
        return .result(value: t, dialog: IntentDialog(stringLiteral: String(format: "Battery temperature is %.1f°C.", t)))
    }
}

// MARK: - Actions

public struct PauseChargingIntent: AppIntent {
    public static let title: LocalizedStringResource = "Pause or Resume Charging"
    public static let description = IntentDescription("Pause: stops charging at the current percentage by lowering the charge limit to it (the previous limit is remembered). Resume: restores the remembered limit.")

    @Parameter(title: "Pause Charging", default: true)
    public var pause: Bool

    public init() {}

    private static let savedLimitKey = "chargecap.pausedPreviousLimit"

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let controller = ChargeController.shared
        let prefs = Prefs.shared
        let defaults = UserDefaults.standard
        if pause {
            controller.refreshNow()
            let current = min(100, max(10, controller.snapshot.osPercentage))
            if defaults.object(forKey: Self.savedLimitKey) == nil {
                defaults.set(prefs.chargeLimit, forKey: Self.savedLimitKey)
            }
            controller.isTopUpActive = false
            if current < 20 { prefs.allowLowLimits = true }
            controller.setChargeLimit(current)
            return .result(dialog: "Charging paused at \(current)%.")
        } else {
            let restored = (defaults.object(forKey: Self.savedLimitKey) as? Int) ?? prefs.chargeLimit
            defaults.removeObject(forKey: Self.savedLimitKey)
            controller.setChargeLimit(min(100, max(10, restored)))
            return .result(dialog: "Charging resumed with limit \(restored)%.")
        }
    }
}

public struct StopDischargeIntent: AppIntent {
    public static let title: LocalizedStringResource = "Stop Discharging"
    public static let description = IntentDescription("Stops an active discharge and lets the Mac use adapter power again.")

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        ChargeController.shared.setManualDischarge(false)
        return .result(dialog: "Active discharge stopped.")
    }
}

public struct SetMagSafeLEDIntent: AppIntent {
    public static let title: LocalizedStringResource = "Set MagSafe LED Mode"
    public static let description = IntentDescription("Chooses how the MagSafe LED behaves.")

    @Parameter(title: "Mode", default: .auto)
    public var mode: MagSafeLEDOption

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        Prefs.shared.magSafeLEDMode = mode.mode
        ChargeController.shared.evaluateAndApply()
        return .result(dialog: IntentDialog(stringLiteral: "MagSafe LED: \(mode.mode.title)."))
    }
}

public struct SetLowPowerModeIntent: AppIntent {
    public static let title: LocalizedStringResource = "Set Low Power Mode Policy"
    public static let description = IntentDescription("Chooses when ChargeCap keeps Low Power Mode on: always, never, only on battery, only on the adapter, or managed by macOS.")

    @Parameter(title: "Policy", default: .alwaysOn)
    public var policy: LowPowerModeOption

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        Prefs.shared.lowPowerModePolicy = policy.policy
        return .result(dialog: IntentDialog(stringLiteral: "Low Power Mode: \(policy.policy.title)."))
    }
}

public struct StartSleepControlIntent: AppIntent {
    public static let title: LocalizedStringResource = "Start Sleep Control"
    public static let description = IntentDescription("Keeps the Mac awake for the chosen duration (ends early on unplug or low battery).")

    @Parameter(title: "Duration", default: .hour1)
    public var duration: SleepControlOption

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        SleepControl.shared.start(duration.duration)
        return .result(dialog: IntentDialog(stringLiteral: "Sleep Control on: \(duration.duration.title)."))
    }
}

public struct StopSleepControlIntent: AppIntent {
    public static let title: LocalizedStringResource = "Stop Sleep Control"
    public static let description = IntentDescription("Lets the Mac sleep normally again.")

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        SleepControl.shared.stop()
        return .result(dialog: "Sleep Control stopped.")
    }
}

public struct ChargeCapShortcutsProvider: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SetChargeLimitIntent(),
            phrases: ["Set battery limit in \(.applicationName)"],
            shortTitle: "Set Charge Limit",
            systemImageName: "battery.75"
        )
        AppShortcut(
            intent: TopUpBatteryIntent(),
            phrases: ["Top up battery with \(.applicationName)"],
            shortTitle: "Top Up to 100%",
            systemImageName: "arrow.up.to.line.circle.fill"
        )
        AppShortcut(
            intent: ToggleDischargeIntent(),
            phrases: ["Discharge battery with \(.applicationName)"],
            shortTitle: "Discharge to Limit",
            systemImageName: "arrow.down.circle.fill"
        )
        AppShortcut(
            intent: GetBatteryStatusIntent(),
            phrases: ["Check battery status in \(.applicationName)"],
            shortTitle: "Battery Status",
            systemImageName: "bolt.batteryblock.fill"
        )
        AppShortcut(
            intent: GetBatteryPercentageIntent(),
            phrases: ["Get battery percentage from \(.applicationName)"],
            shortTitle: "Battery Percentage",
            systemImageName: "battery.100percent"
        )
        AppShortcut(
            intent: GetChargingStateIntent(),
            phrases: ["Get charging state from \(.applicationName)"],
            shortTitle: "Charging State",
            systemImageName: "bolt.fill"
        )
        AppShortcut(
            intent: PauseChargingIntent(),
            phrases: ["Pause charging with \(.applicationName)"],
            shortTitle: "Pause Charging",
            systemImageName: "pause.circle.fill"
        )
        AppShortcut(
            intent: SetLowPowerModeIntent(),
            phrases: ["Set low power mode in \(.applicationName)"],
            shortTitle: "Low Power Mode",
            systemImageName: "leaf.fill"
        )
        AppShortcut(
            intent: StartSleepControlIntent(),
            phrases: ["Keep Mac awake with \(.applicationName)"],
            shortTitle: "Sleep Control",
            systemImageName: "moon.zzz.fill"
        )
        AppShortcut(
            intent: GetBatteryTemperatureIntent(),
            phrases: ["Get battery temperature from \(.applicationName)"],
            shortTitle: "Battery Temperature",
            systemImageName: "thermometer.medium"
        )
    }
}
