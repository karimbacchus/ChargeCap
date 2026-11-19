//
// HelperToolProtocol.swift
// ChargeCapCore (forked from AlDente)
//
// MIT License
//

import Foundation

public enum ChargeCapConstants {
    public static let appBundleIdentifier = "com.chargecap.app"
    public static let helperMachServiceName = "com.chargecap.app.helper"
    public static let helperVersion = "28.0"
    public static let urlScheme = "chargecap"
}

public enum MagSafeLEDMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case auto = "auto"         // Follows ChargeCap state (Orange charging, Green capped/sailing, Blink thermal)
    case green = "green"       // Force solid green (0x03)
    case orange = "orange"     // Force solid amber/orange (0x04)
    case off = "off"           // LED off / stealth mode (0x01)
    case system = "system"     // macOS default (0x00)

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .auto: return "Sync with ChargeCap"
        case .green: return "Always Green"
        case .orange: return "Always Amber"
        case .off: return "Off (Stealth)"
        case .system: return "macOS Default"
        }
    }

    public var smcByte: UInt8 {
        switch self {
        case .system: return 0x00
        case .off: return 0x01
        case .green: return 0x03
        case .orange: return 0x04
        case .auto: return 0x03
        }
    }
}

public enum SMCKeyFamily: String, Codable, Sendable, CaseIterable {
    case appleSiliconModern = "Apple Silicon (CBTC/CHIE)"
    case appleSiliconCHTE   = "Apple Silicon (CHTE/CHIE)"
    case appleSiliconLegacy = "Apple Silicon Legacy (CH0B/CH0C/CH0I)"
    case intelClassic       = "Intel Classic (BCLM/BFCL)"

    public static func detect() -> SMCKeyFamily {
        if SMCKit.isKeyFound("CHTE") {
            return .appleSiliconCHTE
        }
        if SMCKit.isKeyFound("CBTC") || SMCKit.isKeyFound("CHIB") || SMCKit.isKeyFound("CHCE") {
            return .appleSiliconModern
        }
        if SMCKit.isKeyFound("CH0B") || SMCKit.isKeyFound("CH0C") {
            return .appleSiliconLegacy
        }
        if SMCKit.isKeyFound("BCLM") {
            return .intelClassic
        }
        return .appleSiliconModern
    }
}

@objc(HelperToolProtocol)
public protocol HelperToolProtocol {
    func getVersion(withReply reply: @escaping (String) -> Void)
    /// Applies charging / force-discharge / LED state in one call. `ledByte` 0xFF = leave the LED alone.
    func applyState(chargingEnabled: Bool, forceDischarge: Bool, ledByte: UInt8, withReply reply: @escaping (Bool, String) -> Void)
    /// Runs `pmset -a|-b|-c lowpowermode 0|1`. `scope` is a PowerSourceScope raw value.
    func setLowPowerMode(enabled: Bool, scope: String, withReply reply: @escaping (Bool, String) -> Void)
    func setMaxBatteryCharge(_ setVal: UInt8, withReply reply: @escaping (Bool) -> Void)
    /// Only allowlisted charge-control keys may be written.
    func setSMCBytes(key: String, bytes: [UInt8], withReply reply: @escaping (Bool) -> Void)
    /// Only allowlisted charge-control and telemetry keys may be read.
    func readSMCBytes(key: String, withReply reply: @escaping ([UInt8]) -> Void)
    func resetAll(withReply reply: @escaping (Bool) -> Void)
}
