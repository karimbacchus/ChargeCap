//
// Prefs.swift
// ChargeCap (forked from AlDente PersistanceManager.swift)
//
// MIT License
//

import ChargeCapCore
import Combine
import Foundation
import ServiceManagement

public enum MenuBarIconStyle: String, CaseIterable, Codable, Identifiable {
    case ringGauge = "ring"
    case batteryCapsule = "battery"
    case minimalBolt = "bolt"
    case textOnly = "text"
    /// Icon that reflects the live state (charging, held, discharging, heat paused…).
    case liveStatus = "live"
    /// Mimics the native macOS battery glyph.
    case macOSBattery = "macos"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .ringGauge: return "AlDente Ring Gauge"
        case .batteryCapsule: return "Battery Capsule with Limit Line"
        case .minimalBolt: return "Minimal Status Symbol"
        case .textOnly: return "Text Readout Only"
        case .liveStatus: return "Live Status Icon"
        case .macOSBattery: return "macOS Battery Style"
        }
    }
}

public enum MenuBarRightClickAction: String, CaseIterable, Codable, Identifiable {
    case quickMenu, openSettings, toggleTopUp

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .quickMenu: return "Show Quick Menu"
        case .openSettings: return "Open Settings"
        case .toggleTopUp: return "Toggle Top Up"
        }
    }
}

public enum LowPowerModePolicy: String, CaseIterable, Codable, Identifiable {
    case unmanaged, alwaysOff, alwaysOn, onlyOnBattery, onlyOnAdapter

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .unmanaged: return "Managed by macOS"
        case .alwaysOff: return "Always Off"
        case .alwaysOn: return "Always On"
        case .onlyOnBattery: return "Only on Battery"
        case .onlyOnAdapter: return "Only on Power Adapter"
        }
    }

    /// Desired Low Power Mode state for (battery, adapter), or nil when unmanaged.
    public var desiredState: (battery: Bool, adapter: Bool)? {
        switch self {
        case .unmanaged: return nil
        case .alwaysOff: return (false, false)
        case .alwaysOn: return (true, true)
        case .onlyOnBattery: return (true, false)
        case .onlyOnAdapter: return (false, true)
        }
    }
}

public enum PopoverWidget: String, CaseIterable, Codable, Identifiable {
    case controls, powerFlow, specifications, graphs, energyApps, lowPowerMode, sleepControl

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .controls: return "Controls"
        case .powerFlow: return "Power Flow"
        case .specifications: return "Specifications"
        case .graphs: return "Graphs"
        case .energyApps: return "Apps Using Significant Energy"
        case .lowPowerMode: return "Low Power Mode"
        case .sleepControl: return "Sleep Control"
        }
    }
}

public enum MenuBarReadoutMode: String, CaseIterable, Codable, Identifiable {
    case percentage = "percent"
    case hardwarePercentage = "hw_percent"
    case powerWatts = "watts"
    case temperature = "temp"
    case percentAndPower = "percent_watts"
    case timeRemaining = "time"
    case health = "health"
    case cycles = "cycles"
    case none = "none"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .percentage: return "macOS Battery %"
        case .hardwarePercentage: return "Hardware BMS %"
        case .powerWatts: return "Live Power (W)"
        case .temperature: return "Battery Temp"
        case .percentAndPower: return "Battery % + Power (W)"
        case .timeRemaining: return "Time Remaining"
        case .health: return "Battery Health %"
        case .cycles: return "Cycle Count"
        case .none: return "Icon Only"
        }
    }
}

@MainActor
public final class Prefs: ObservableObject {
    public static let shared = Prefs()

    public static let devMode: Bool = CommandLine.arguments.contains("--dev") || CommandLine.arguments.contains("--selftest")

    private let defaults: UserDefaults

    @Published public var chargeLimit: Int {
        didSet {
            let clamped = min(100, max(minAllowedChargeLimit, chargeLimit))
            if clamped != chargeLimit { chargeLimit = clamped; return }
            defaults.set(chargeLimit, forKey: "chargeLimit")
        }
    }

    @Published public var allowLowLimits: Bool {
        didSet {
            defaults.set(allowLowLimits, forKey: "allowLowLimits")
            if !allowLowLimits && chargeLimit < 20 {
                chargeLimit = 20
            }
        }
    }

    @Published public var useHardwarePercentage: Bool {
        didSet { defaults.set(useHardwarePercentage, forKey: "useHardwarePercentage") }
    }

    @Published public var sailingModeEnabled: Bool {
        didSet { defaults.set(sailingModeEnabled, forKey: "sailingModeEnabled") }
    }

    @Published public var sailingDelta: Int {
        didSet {
            let clamped = min(30, max(1, sailingDelta))
            if clamped != sailingDelta { sailingDelta = clamped; return }
            defaults.set(sailingDelta, forKey: "sailingDelta")
        }
    }

    @Published public var heatProtectionEnabled: Bool {
        didSet { defaults.set(heatProtectionEnabled, forKey: "heatProtectionEnabled") }
    }

    @Published public var heatProtectionMaxCelsius: Double {
        didSet {
            let clamped = min(48.0, max(25.0, heatProtectionMaxCelsius))
            if clamped != heatProtectionMaxCelsius { heatProtectionMaxCelsius = clamped; return }
            defaults.set(heatProtectionMaxCelsius, forKey: "heatProtectionMaxCelsius")
        }
    }

    @Published public var autoDischargeEnabled: Bool {
        didSet { defaults.set(autoDischargeEnabled, forKey: "autoDischargeEnabled") }
    }

    @Published public var dischargeInClamshell: Bool {
        didSet { defaults.set(dischargeInClamshell, forKey: "dischargeInClamshell") }
    }

    @Published public var stopChargingWhenSleeping: Bool {
        didSet { defaults.set(stopChargingWhenSleeping, forKey: "stopChargingWhenSleeping") }
    }

    @Published public var disableSleepUntilChargeLimit: Bool {
        didSet { defaults.set(disableSleepUntilChargeLimit, forKey: "disableSleepUntilChargeLimit") }
    }

    /// Keep charging inhibited after ChargeCap quits (formerly `stopChargingWhenPoweredOff`).
    @Published public var stopChargingWhenAppClosed: Bool {
        didSet { defaults.set(stopChargingWhenAppClosed, forKey: "stopChargingWhenAppClosed") }
    }

    @Published public var topUpAutoRevertOnUnplug: Bool {
        didSet { defaults.set(topUpAutoRevertOnUnplug, forKey: "topUpAutoRevertOnUnplug") }
    }

    @Published public var topUpAutoRevertAt100: Bool {
        didSet { defaults.set(topUpAutoRevertAt100, forKey: "topUpAutoRevertAt100") }
    }

    @Published public var magSafeLEDMode: MagSafeLEDMode {
        didSet { defaults.set(magSafeLEDMode.rawValue, forKey: "magSafeLEDMode") }
    }

    @Published public var menuBarIconStyle: MenuBarIconStyle {
        didSet { defaults.set(menuBarIconStyle.rawValue, forKey: "menuBarIconStyle") }
    }

    @Published public var menuBarReadoutMode: MenuBarReadoutMode {
        didSet { defaults.set(menuBarReadoutMode.rawValue, forKey: "menuBarReadoutMode") }
    }

    @Published public var temperatureUnitFahrenheit: Bool {
        didSet { defaults.set(temperatureUnitFahrenheit, forKey: "temperatureUnitFahrenheit") }
    }

    @Published public var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: "notificationsEnabled") }
    }

    @Published public var useClassicIntelKey: Bool {
        didSet { defaults.set(useClassicIntelKey, forKey: "useClassicIntelKey") }
    }

    @Published public var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: "launchAtLogin")
            guard !Self.devMode else { return }
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                // Ignore registration error when running outside /Applications
            }
        }
    }

    // MARK: Phase 2 additions

    @Published public var ledBlinkWhileDischarging: Bool {
        didSet { defaults.set(ledBlinkWhileDischarging, forKey: "ledBlinkWhileDischarging") }
    }
    @Published public var ledOffDuringSleep: Bool {
        didSet { defaults.set(ledOffDuringSleep, forKey: "ledOffDuringSleep") }
    }
    @Published public var lowPowerModePolicy: LowPowerModePolicy {
        didSet { defaults.set(lowPowerModePolicy.rawValue, forKey: "lowPowerModePolicy") }
    }
    /// Telemetry refresh interval in seconds (2...20).
    @Published public var refreshIntervalSeconds: Int {
        didSet {
            let clamped = min(20, max(2, refreshIntervalSeconds))
            if clamped != refreshIntervalSeconds { refreshIntervalSeconds = clamped; return }
            defaults.set(refreshIntervalSeconds, forKey: "refreshIntervalSeconds")
        }
    }
    @Published public var menuBarRightClickAction: MenuBarRightClickAction {
        didSet { defaults.set(menuBarRightClickAction.rawValue, forKey: "menuBarRightClickAction") }
    }
    @Published public var menuBarLowPowerTint: Bool {
        didSet { defaults.set(menuBarLowPowerTint, forKey: "menuBarLowPowerTint") }
    }
    @Published public var popoverWidgetOrder: [PopoverWidget] {
        didSet {
            let normalized = Self.normalizedOrder(popoverWidgetOrder)
            if normalized != popoverWidgetOrder { popoverWidgetOrder = normalized; return }
            defaults.set(popoverWidgetOrder.map(\.rawValue), forKey: "popoverWidgetOrder")
        }
    }
    @Published public var hiddenPopoverWidgets: Set<PopoverWidget> {
        didSet { defaults.set(hiddenPopoverWidgets.map(\.rawValue).sorted(), forKey: "hiddenPopoverWidgets") }
    }
    @Published public var hasCompletedOnboarding: Bool {
        didSet { defaults.set(hasCompletedOnboarding, forKey: "hasCompletedOnboarding") }
    }
    @Published public var energyThreshold: EnergyThreshold {
        didSet { defaults.set(energyThreshold.rawValue, forKey: "energyThreshold"); pushToServices() }
    }
    @Published public var energyIncludeBackground: Bool {
        didSet { defaults.set(energyIncludeBackground, forKey: "energyIncludeBackground"); pushToServices() }
    }
    @Published public var sleepControlReenableBelowPercent: Int {
        didSet {
            let clamped = min(90, max(5, sleepControlReenableBelowPercent))
            if clamped != sleepControlReenableBelowPercent { sleepControlReenableBelowPercent = clamped; return }
            defaults.set(sleepControlReenableBelowPercent, forKey: "sleepControlReenableBelowPercent")
            pushToServices()
        }
    }
    @Published public var sleepControlStopOnUnplug: Bool {
        didSet { defaults.set(sleepControlStopOnUnplug, forKey: "sleepControlStopOnUnplug"); pushToServices() }
    }
    @Published public var sleepControlKeepDisplayAwake: Bool {
        didSet { defaults.set(sleepControlKeepDisplayAwake, forKey: "sleepControlKeepDisplayAwake"); pushToServices() }
    }
    @Published public var notifyLimitReached: Bool {
        didSet { defaults.set(notifyLimitReached, forKey: "notifyLimitReached") }
    }
    @Published public var notifyTopUp: Bool {
        didSet { defaults.set(notifyTopUp, forKey: "notifyTopUp") }
    }
    @Published public var notifyDischarge: Bool {
        didSet { defaults.set(notifyDischarge, forKey: "notifyDischarge") }
    }
    @Published public var notifyHeat: Bool {
        didSet { defaults.set(notifyHeat, forKey: "notifyHeat") }
    }
    @Published public var notifyCalibration: Bool {
        didSet { defaults.set(notifyCalibration, forKey: "notifyCalibration") }
    }
    @Published public var notifySchedule: Bool {
        didSet { defaults.set(notifySchedule, forKey: "notifySchedule") }
    }
    @Published public var scheduleCatchUpMissed: Bool {
        didSet { defaults.set(scheduleCatchUpMissed, forKey: "scheduleCatchUpMissed") }
    }

    public static let defaultPopoverWidgetOrder: [PopoverWidget] =
        [.controls, .powerFlow, .specifications, .graphs, .energyApps, .lowPowerMode, .sleepControl]
    public static let defaultHiddenPopoverWidgets: Set<PopoverWidget> =
        [.energyApps, .lowPowerMode, .sleepControl]

    /// Drops duplicates and appends any widget missing from the stored order.
    private static func normalizedOrder(_ order: [PopoverWidget]) -> [PopoverWidget] {
        var seen = Set<PopoverWidget>()
        var result = order.filter { seen.insert($0).inserted }
        for w in PopoverWidget.allCases where !seen.contains(w) { result.append(w) }
        return result
    }

    /// Pushes prefs that live in standalone services (the prefs are the source of truth).
    public func pushToServices() {
        EnergyMonitor.shared.threshold = energyThreshold
        EnergyMonitor.shared.includeBackgroundProcesses = energyIncludeBackground
        SleepControl.shared.reenableBelowPercent = sleepControlReenableBelowPercent
        SleepControl.shared.stopOnUnplug = sleepControlStopOnUnplug
        SleepControl.shared.keepDisplayAwake = sleepControlKeepDisplayAwake
    }

    public var minAllowedChargeLimit: Int {
        allowLowLimits ? 10 : 20
    }

    public var sailingTarget: Int {
        max(minAllowedChargeLimit, chargeLimit - sailingDelta)
    }

    public let quickPresets: [Int] = [50, 60, 70, 80, 90, 100]

    private init() {
        let store: UserDefaults
        if Self.devMode, let devStore = UserDefaults(suiteName: "com.chargecap.app.dev") {
            store = devStore
        } else {
            store = .standard
        }
        self.defaults = store

        store.register(defaults: [
            "chargeLimit": 80,
            "allowLowLimits": false,
            "useHardwarePercentage": false,
            "sailingModeEnabled": true,
            "sailingDelta": 5,
            "heatProtectionEnabled": true,
            "heatProtectionMaxCelsius": 35.0,
            "autoDischargeEnabled": false,
            "dischargeInClamshell": false,
            "stopChargingWhenSleeping": true,
            "disableSleepUntilChargeLimit": false,
            "stopChargingWhenAppClosed": false,
            "topUpAutoRevertOnUnplug": true,
            "topUpAutoRevertAt100": true,
            "magSafeLEDMode": MagSafeLEDMode.auto.rawValue,
            "menuBarIconStyle": MenuBarIconStyle.ringGauge.rawValue,
            "menuBarReadoutMode": MenuBarReadoutMode.percentage.rawValue,
            "temperatureUnitFahrenheit": false,
            "notificationsEnabled": true,
            "useClassicIntelKey": false,
            "launchAtLogin": false,
            "ledBlinkWhileDischarging": false,
            "ledOffDuringSleep": false,
            "lowPowerModePolicy": LowPowerModePolicy.unmanaged.rawValue,
            "refreshIntervalSeconds": 5,
            "menuBarRightClickAction": MenuBarRightClickAction.quickMenu.rawValue,
            "menuBarLowPowerTint": false,
            "hasCompletedOnboarding": false,
            "energyThreshold": EnergyThreshold.low.rawValue,
            "energyIncludeBackground": false,
            "sleepControlReenableBelowPercent": 20,
            "sleepControlStopOnUnplug": true,
            "sleepControlKeepDisplayAwake": false,
            "notifyLimitReached": true,
            "notifyTopUp": true,
            "notifyDischarge": true,
            "notifyHeat": true,
            "notifyCalibration": true,
            "notifySchedule": true,
            "scheduleCatchUpMissed": true
        ])

        // Migrate the renamed key (stopChargingWhenPoweredOff -> stopChargingWhenAppClosed).
        if let old = store.object(forKey: "stopChargingWhenPoweredOff") as? Bool {
            store.set(old, forKey: "stopChargingWhenAppClosed")
            store.removeObject(forKey: "stopChargingWhenPoweredOff")
        }

        self.allowLowLimits = store.bool(forKey: "allowLowLimits")
        let savedLimit = store.integer(forKey: "chargeLimit")
        self.chargeLimit = (savedLimit >= 10 && savedLimit <= 100) ? savedLimit : 80
        self.useHardwarePercentage = store.bool(forKey: "useHardwarePercentage")
        self.sailingModeEnabled = store.bool(forKey: "sailingModeEnabled")
        let savedDelta = store.integer(forKey: "sailingDelta")
        self.sailingDelta = (savedDelta >= 1 && savedDelta <= 30) ? savedDelta : 5
        self.heatProtectionEnabled = store.bool(forKey: "heatProtectionEnabled")
        let savedTemp = store.double(forKey: "heatProtectionMaxCelsius")
        self.heatProtectionMaxCelsius = (savedTemp >= 25.0 && savedTemp <= 48.0) ? savedTemp : 35.0
        self.autoDischargeEnabled = store.bool(forKey: "autoDischargeEnabled")
        self.dischargeInClamshell = store.bool(forKey: "dischargeInClamshell")
        self.stopChargingWhenSleeping = store.bool(forKey: "stopChargingWhenSleeping")
        self.disableSleepUntilChargeLimit = store.bool(forKey: "disableSleepUntilChargeLimit")
        self.stopChargingWhenAppClosed = store.bool(forKey: "stopChargingWhenAppClosed")
        self.topUpAutoRevertOnUnplug = store.bool(forKey: "topUpAutoRevertOnUnplug")
        self.topUpAutoRevertAt100 = store.bool(forKey: "topUpAutoRevertAt100")
        self.magSafeLEDMode = MagSafeLEDMode(rawValue: store.string(forKey: "magSafeLEDMode") ?? "") ?? .auto
        self.menuBarIconStyle = MenuBarIconStyle(rawValue: store.string(forKey: "menuBarIconStyle") ?? "") ?? .ringGauge
        self.menuBarReadoutMode = MenuBarReadoutMode(rawValue: store.string(forKey: "menuBarReadoutMode") ?? "") ?? .percentage
        self.temperatureUnitFahrenheit = store.bool(forKey: "temperatureUnitFahrenheit")
        self.notificationsEnabled = store.bool(forKey: "notificationsEnabled")
        self.useClassicIntelKey = store.bool(forKey: "useClassicIntelKey")
        self.launchAtLogin = store.bool(forKey: "launchAtLogin")

        self.ledBlinkWhileDischarging = store.bool(forKey: "ledBlinkWhileDischarging")
        self.ledOffDuringSleep = store.bool(forKey: "ledOffDuringSleep")
        self.lowPowerModePolicy = LowPowerModePolicy(rawValue: store.string(forKey: "lowPowerModePolicy") ?? "") ?? .unmanaged
        let savedInterval = store.integer(forKey: "refreshIntervalSeconds")
        self.refreshIntervalSeconds = (2...20).contains(savedInterval) ? savedInterval : 5
        self.menuBarRightClickAction = MenuBarRightClickAction(rawValue: store.string(forKey: "menuBarRightClickAction") ?? "") ?? .quickMenu
        self.menuBarLowPowerTint = store.bool(forKey: "menuBarLowPowerTint")
        let storedOrder = (store.stringArray(forKey: "popoverWidgetOrder") ?? []).compactMap(PopoverWidget.init(rawValue:))
        self.popoverWidgetOrder = Self.normalizedOrder(storedOrder.isEmpty ? Self.defaultPopoverWidgetOrder : storedOrder)
        if let hidden = store.stringArray(forKey: "hiddenPopoverWidgets") {
            self.hiddenPopoverWidgets = Set(hidden.compactMap(PopoverWidget.init(rawValue:)))
        } else {
            self.hiddenPopoverWidgets = Self.defaultHiddenPopoverWidgets
        }
        self.hasCompletedOnboarding = store.bool(forKey: "hasCompletedOnboarding")
        self.energyThreshold = EnergyThreshold(rawValue: store.string(forKey: "energyThreshold") ?? "") ?? .low
        self.energyIncludeBackground = store.bool(forKey: "energyIncludeBackground")
        let savedReenable = store.integer(forKey: "sleepControlReenableBelowPercent")
        self.sleepControlReenableBelowPercent = (5...90).contains(savedReenable) ? savedReenable : 20
        self.sleepControlStopOnUnplug = store.bool(forKey: "sleepControlStopOnUnplug")
        self.sleepControlKeepDisplayAwake = store.bool(forKey: "sleepControlKeepDisplayAwake")
        self.notifyLimitReached = store.bool(forKey: "notifyLimitReached")
        self.notifyTopUp = store.bool(forKey: "notifyTopUp")
        self.notifyDischarge = store.bool(forKey: "notifyDischarge")
        self.notifyHeat = store.bool(forKey: "notifyHeat")
        self.notifyCalibration = store.bool(forKey: "notifyCalibration")
        self.notifySchedule = store.bool(forKey: "notifySchedule")
        self.scheduleCatchUpMissed = store.bool(forKey: "scheduleCatchUpMissed")

        pushToServices()
    }

    public func formatTemperature(_ celsius: Double) -> String {
        if temperatureUnitFahrenheit {
            let f = (celsius * 1.8) + 32.0
            return String(format: "%.1f°F", f)
        } else {
            return String(format: "%.1f°C", celsius)
        }
    }
}
