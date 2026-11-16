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

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .ringGauge: return "AlDente Ring Gauge"
        case .batteryCapsule: return "Battery Capsule with Limit Line"
        case .minimalBolt: return "Minimal Status Symbol"
        case .textOnly: return "Text Readout Only"
        }
    }
}

public enum MenuBarReadoutMode: String, CaseIterable, Codable, Identifiable {
    case percentage = "percent"
    case hardwarePercentage = "hw_percent"
    case powerWatts = "watts"
    case temperature = "temp"
    case percentAndPower = "percent_watts"
    case none = "none"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .percentage: return "macOS Battery %"
        case .hardwarePercentage: return "Hardware BMS %"
        case .powerWatts: return "Live Power (W)"
        case .temperature: return "Battery Temp"
        case .percentAndPower: return "Battery % + Power (W)"
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

    @Published public var stopChargingWhenPoweredOff: Bool {
        didSet { defaults.set(stopChargingWhenPoweredOff, forKey: "stopChargingWhenPoweredOff") }
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
            "heatProtectionMaxCelsius": 40.0,
            "autoDischargeEnabled": false,
            "dischargeInClamshell": false,
            "stopChargingWhenSleeping": true,
            "disableSleepUntilChargeLimit": false,
            "stopChargingWhenPoweredOff": false,
            "topUpAutoRevertOnUnplug": true,
            "topUpAutoRevertAt100": true,
            "magSafeLEDMode": MagSafeLEDMode.auto.rawValue,
            "menuBarIconStyle": MenuBarIconStyle.ringGauge.rawValue,
            "menuBarReadoutMode": MenuBarReadoutMode.percentage.rawValue,
            "temperatureUnitFahrenheit": false,
            "notificationsEnabled": true,
            "useClassicIntelKey": false,
            "launchAtLogin": false
        ])

        self.allowLowLimits = store.bool(forKey: "allowLowLimits")
        let savedLimit = store.integer(forKey: "chargeLimit")
        self.chargeLimit = (savedLimit >= 10 && savedLimit <= 100) ? savedLimit : 80
        self.useHardwarePercentage = store.bool(forKey: "useHardwarePercentage")
        self.sailingModeEnabled = store.bool(forKey: "sailingModeEnabled")
        let savedDelta = store.integer(forKey: "sailingDelta")
        self.sailingDelta = (savedDelta >= 1 && savedDelta <= 30) ? savedDelta : 5
        self.heatProtectionEnabled = store.bool(forKey: "heatProtectionEnabled")
        let savedTemp = store.double(forKey: "heatProtectionMaxCelsius")
        self.heatProtectionMaxCelsius = (savedTemp >= 25.0 && savedTemp <= 48.0) ? savedTemp : 40.0
        self.autoDischargeEnabled = store.bool(forKey: "autoDischargeEnabled")
        self.dischargeInClamshell = store.bool(forKey: "dischargeInClamshell")
        self.stopChargingWhenSleeping = store.bool(forKey: "stopChargingWhenSleeping")
        self.disableSleepUntilChargeLimit = store.bool(forKey: "disableSleepUntilChargeLimit")
        self.stopChargingWhenPoweredOff = store.bool(forKey: "stopChargingWhenPoweredOff")
        self.topUpAutoRevertOnUnplug = store.bool(forKey: "topUpAutoRevertOnUnplug")
        self.topUpAutoRevertAt100 = store.bool(forKey: "topUpAutoRevertAt100")
        self.magSafeLEDMode = MagSafeLEDMode(rawValue: store.string(forKey: "magSafeLEDMode") ?? "") ?? .auto
        self.menuBarIconStyle = MenuBarIconStyle(rawValue: store.string(forKey: "menuBarIconStyle") ?? "") ?? .ringGauge
        self.menuBarReadoutMode = MenuBarReadoutMode(rawValue: store.string(forKey: "menuBarReadoutMode") ?? "") ?? .percentage
        self.temperatureUnitFahrenheit = store.bool(forKey: "temperatureUnitFahrenheit")
        self.notificationsEnabled = store.bool(forKey: "notificationsEnabled")
        self.useClassicIntelKey = store.bool(forKey: "useClassicIntelKey")
        self.launchAtLogin = store.bool(forKey: "launchAtLogin")
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
