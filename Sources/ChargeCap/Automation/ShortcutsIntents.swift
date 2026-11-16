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
    }
}
