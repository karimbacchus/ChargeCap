//
// URLCommands.swift
// ChargeCap
//
// MIT License
//

import ChargeCapCore
import Foundation

/// Handles `chargecap://` automation URLs from Shortcuts, Raycast, Alfred, or CLI.
///
/// Supported URLs:
/// - `chargecap://set-limit?percent=80`
/// - `chargecap://top-up?enable=true`
/// - `chargecap://discharge?enable=true`
/// - `chargecap://calibrate?action=start|next|stop`
/// - `chargecap://sailing?enable=true&delta=5`
/// - `chargecap://heat-protection?enable=true&maxTemp=35`
/// - `chargecap://magsafe?mode=auto|green|orange|off|system` (alias: `led`)
/// - `chargecap://low-power?mode=on|off|battery|adapter|unmanaged`
/// - `chargecap://sleep-control?duration=30m|1h|2h|5h|forever|off`
/// - `chargecap://pause` (pauses charging at the current %; `pause?enable=false` resumes)
/// - `chargecap://status` (refreshes telemetry)
/// - `chargecap://open-settings?section=<name>` (posts `Notification.Name.chargeCapOpenSettings`)
@MainActor
public enum URLCommands {
    private static let pausedLimitKey = "chargecap.pausedPreviousLimit"

    @discardableResult
    public static func handle(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == ChargeCapConstants.urlScheme else { return false }
        let command = (url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))).lowercased()
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []

        func param(_ name: String) -> String? {
            queryItems.first { $0.name.lowercased() == name.lowercased() }?.value
        }

        func boolParam(_ name: String, default fallback: Bool = true) -> Bool {
            guard let raw = param(name)?.lowercased() else { return fallback }
            return raw == "1" || raw == "true" || raw == "yes" || raw == "on"
        }

        let controller = ChargeController.shared
        let prefs = Prefs.shared

        switch command {
        case "set-limit", "limit":
            if let raw = param("percent") ?? param("value"), let val = Int(raw), (10...100).contains(val) {
                if val < 20 { prefs.allowLowLimits = true }
                controller.setChargeLimit(val)
                return true
            }
            return false

        case "top-up", "topup":
            let enable = boolParam("enable", default: !controller.isTopUpActive)
            controller.isTopUpActive = enable
            return true

        case "discharge":
            let enable = boolParam("enable", default: !controller.isManualDischargeActive)
            controller.isManualDischargeActive = enable
            return true

        case "calibrate", "calibration":
            let action = param("action")?.lowercased() ?? "start"
            switch action {
            case "stop", "cancel":
                controller.stopCalibration()
            case "next", "step":
                controller.advanceCalibrationStep()
            default:
                controller.startCalibration()
            }
            return true

        case "sailing":
            if param("enable") != nil {
                prefs.sailingModeEnabled = boolParam("enable")
            }
            if let d = param("delta"), let delta = Int(d), (1...30).contains(delta) {
                prefs.sailingDelta = delta
            }
            controller.evaluateAndApply()
            return true

        case "heat-protection", "thermal":
            if param("enable") != nil {
                prefs.heatProtectionEnabled = boolParam("enable")
            }
            if let t = param("maxTemp") ?? param("temp"), let temp = Double(t), (25...48).contains(temp) {
                prefs.heatProtectionMaxCelsius = temp
            }
            controller.evaluateAndApply()
            return true

        case "magsafe", "led":
            if let modeStr = param("mode")?.lowercased(),
               let mode = MagSafeLEDMode(rawValue: modeStr) {
                prefs.magSafeLEDMode = mode
                controller.evaluateAndApply()
                return true
            }
            return false

        case "low-power", "lowpower", "low-power-mode":
            let policy: LowPowerModePolicy
            switch param("mode")?.lowercased() {
            case "on", "always-on": policy = .alwaysOn
            case "off", "always-off": policy = .alwaysOff
            case "battery": policy = .onlyOnBattery
            case "adapter", "power-adapter": policy = .onlyOnAdapter
            case "unmanaged", "system", "auto": policy = .unmanaged
            default: return false
            }
            prefs.lowPowerModePolicy = policy
            return true

        case "sleep-control", "sleepcontrol":
            let sleep = SleepControl.shared
            switch param("duration")?.lowercased() {
            case "off", "stop", "cancel", "0":
                sleep.stop()
            case "30m": sleep.start(.minutes30)
            case "1h": sleep.start(.hour1)
            case "2h": sleep.start(.hours2)
            case "5h": sleep.start(.hours5)
            case "forever", "indefinitely", "inf":
                sleep.start(.indefinitely)
            default: return false
            }
            return true

        case "pause":
            let defaults = UserDefaults.standard
            if boolParam("enable", default: true) {
                controller.refreshNow()
                let current = min(100, max(10, controller.snapshot.osPercentage))
                if defaults.object(forKey: pausedLimitKey) == nil {
                    defaults.set(prefs.chargeLimit, forKey: pausedLimitKey)
                }
                controller.isTopUpActive = false
                if current < 20 { prefs.allowLowLimits = true }
                controller.setChargeLimit(current)
            } else {
                let restored = (defaults.object(forKey: pausedLimitKey) as? Int) ?? prefs.chargeLimit
                defaults.removeObject(forKey: pausedLimitKey)
                controller.setChargeLimit(min(100, max(10, restored)))
            }
            return true

        case "status":
            controller.refreshNow()
            return true

        case "open-settings", "settings":
            var info: [String: Any] = [:]
            if let section = param("section"), !section.isEmpty {
                info["section"] = String(section.prefix(40))
            }
            NotificationCenter.default.post(name: .chargeCapOpenSettings, object: nil, userInfo: info)
            return true

        default:
            return false
        }
    }
}

public extension Notification.Name {
    /// Posted by `chargecap://open-settings`; `userInfo["section"]` is an optional String.
    static let chargeCapOpenSettings = Notification.Name("ChargeCapOpenSettings")
}
