//
// HelperToolProtocol.swift
// ChargeCapCore (forked from AlDente)
//
// MIT License
//

import Foundation
import IOKit.pwr_mgt

public enum ChargeCapConstants {
    public static let appBundleIdentifier = "com.chargecap.app"
    public static let helperMachServiceName = "com.chargecap.app.helper"
    public static let helperDaemonPlistName = "com.chargecap.app.helper.plist"
    public static let helperVersion = "27.1"
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
    case appleSiliconModern = "Apple Silicon (CHIB/CHCE/CHIE)"
    case appleSiliconCHTE   = "Apple Silicon (CHTE/CHIE)"
    case appleSiliconLegacy = "Apple Silicon Legacy (CH0B/CH0C/CH0I)"
    case intelClassic       = "Intel Classic (BCLM/BFCL)"

    public static func detect() -> SMCKeyFamily {
        if SMCKit.isKeyFound("CHTE") {
            return .appleSiliconCHTE
        }
        if SMCKit.isKeyFound("CHIB") || SMCKit.isKeyFound("CHCE") {
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
    func setChargingEnabled(_ enabled: Bool, withReply reply: @escaping (Bool, String) -> Void)
    func setForceDischarge(_ discharge: Bool, withReply reply: @escaping (Bool, String) -> Void)
    func setMagSafeLED(_ value: UInt8, withReply reply: @escaping (Bool) -> Void)
    func setMaxBatteryCharge(_ setVal: UInt8, withReply reply: @escaping (Bool) -> Void)
    func setSMCBytes(key: String, bytes: [UInt8], withReply reply: @escaping (Bool) -> Void)
    func readSMCBytes(key: String, withReply reply: @escaping ([UInt8]) -> Void)
    func createAssertion(assertion: String, reason: String, withReply reply: @escaping (IOPMAssertionID) -> Void)
    func releaseAssertion(assertionID: IOPMAssertionID)
    func resetAll(withReply reply: @escaping (Bool) -> Void)
}
