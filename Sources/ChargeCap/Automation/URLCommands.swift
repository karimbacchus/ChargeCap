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
/// - `chargecap://magsafe?mode=auto|green|orange|off|system`
@MainActor
public enum URLCommands {
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

        case "magsafe":
            if let modeStr = param("mode")?.lowercased(),
               let mode = MagSafeLEDMode(rawValue: modeStr) {
                prefs.magSafeLEDMode = mode
                controller.evaluateAndApply()
                return true
            }
            return false

        default:
            return false
        }
    }
}
