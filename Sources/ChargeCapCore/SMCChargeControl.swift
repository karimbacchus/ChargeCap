//
// SMCChargeControl.swift
// ChargeCapCore
//
// Single source of truth for the SMC key/value semantics used to inhibit charging,
// force discharge and drive the MagSafe LED. Used by the root helper and by the
// app's direct-SMC fallback (when the app itself runs as root).
//
// MIT License
//

import Foundation
import Security

public enum SMCChargeControl {
    /// Writes bytes to an SMC key; returns true on success. The helper supplies a writer
    /// that also records original values for restoration.
    public typealias Writer = (_ key: String, _ bytes: [UInt8]) -> Bool

    /// LED byte meaning "leave the LED alone" in `applyState`.
    public static let ledUntouched: UInt8 = 0xFF

    public static let chargeKeys = ["CBTC", "CHIB", "CHIC", "CHCE", "CHCC", "CHTE", "CH0B", "CH0C"]
    public static let dischargeKeys = ["CHIE", "CH0I", "CH0J"]
    public static let ledKeys = ["ACLC"]
    public static let classicLimitKeys = ["BCLM", "BFCL"]

    /// Keys the helper may write.
    public static let writableKeys: Set<String> =
        Set(chargeKeys + dischargeKeys + ledKeys + classicLimitKeys)

    /// Read-only telemetry keys the helper may additionally read.
    public static let readOnlyKeys: Set<String> = [
        "TB0T", "TB1T", "TB2T", "B0AT", "BC1V", "BC2V", "BC3V",
        "B0RM", "B0FC", "B0AV", "B0AC"
    ]

    public static var readableKeys: Set<String> { writableKeys.union(readOnlyKeys) }

    /// Keys shown on the diagnostics page (read-only).
    public static var diagnosticKeys: [String] { chargeKeys + dischargeKeys + ledKeys + classicLimitKeys }

    // MARK: - Writes

    /// Inhibit / allow charging across all key families. When enabling, also clears force-discharge.
    @discardableResult
    public static func setCharging(_ enabled: Bool, write: Writer) -> (ok: Bool, keys: [String]) {
        var applied: [String] = []
        func put(_ key: String, _ bytes: [UInt8]) {
            if SMCKit.isKeyFound(key), write(key, bytes) { applied.append(key) }
        }

        // Modern Apple Silicon M3/M4/M5 / macOS 27 keys
        put("CBTC", [enabled ? 0x01 : 0x00])
        put("CHIB", [enabled ? 0x00 : 0x02])
        put("CHIC", [enabled ? 0x00 : 0x02])
        put("CHCE", [enabled ? 0x01 : 0x00])
        put("CHCC", [enabled ? 0x01 : 0x00])
        // Apple Silicon CHTE (4-byte UInt32)
        put("CHTE", enabled ? [0x00, 0x00, 0x00, 0x00] : [0x01, 0x00, 0x00, 0x00])
        // Apple Silicon M1/M2 legacy keys
        put("CH0B", [enabled ? 0x00 : 0x02])
        put("CH0C", [enabled ? 0x00 : 0x02])

        let ok = !applied.isEmpty
        // If enabling charging, also ensure force-discharge is off.
        if enabled {
            for key in dischargeKeys where SMCKit.isKeyFound(key) { _ = write(key, [0x00]) }
        }
        return (ok, applied)
    }

    /// Start / stop force discharge. Starting inhibits charging first.
    @discardableResult
    public static func setForceDischarge(_ discharge: Bool, write: Writer) -> (ok: Bool, keys: [String]) {
        var applied: [String] = []
        if discharge { _ = setCharging(false, write: write) }
        func put(_ key: String, _ bytes: [UInt8]) {
            if SMCKit.isKeyFound(key), write(key, bytes) { applied.append(key) }
        }
        put("CHIE", [discharge ? 0x08 : 0x00])
        put("CH0I", [discharge ? 0x01 : 0x00])
        put("CH0J", [discharge ? 0x01 : 0x00])
        return (!applied.isEmpty, applied)
    }

    @discardableResult
    public static func setMagSafeLED(_ value: UInt8, write: Writer) -> Bool {
        guard SMCKit.isKeyFound("ACLC") else { return false }
        return write("ACLC", [value])
    }

    @discardableResult
    public static func setMaxBatteryCharge(_ value: UInt8, write: Writer) -> Bool {
        var ok = false
        for key in classicLimitKeys where SMCKit.isKeyFound(key) {
            ok = write(key, [value]) || ok
        }
        return ok
    }

    /// Applies the whole desired state in a safe order (discharge off before inhibiting;
    /// inhibit before discharging on).
    public static func applyState(
        chargingEnabled: Bool,
        forceDischarge: Bool,
        ledByte: UInt8,
        write: Writer
    ) -> (ok: Bool, summary: String) {
        var keys: [String] = []
        var ok = true
        if forceDischarge {
            let c = setCharging(false, write: write)
            let d = setForceDischarge(true, write: write)
            keys += c.keys + d.keys
            ok = c.ok && d.ok
        } else {
            let d = setForceDischarge(false, write: write)
            let c = setCharging(chargingEnabled, write: write)
            keys += d.keys + c.keys
            ok = c.ok
        }
        if ledByte != ledUntouched {
            if setMagSafeLED(ledByte, write: write) { keys.append("ACLC") }
        }
        let summary = keys.isEmpty ? "No writable SMC key matched" : keys.joined(separator: ",")
        return (ok, summary)
    }
}

// MARK: - Code signing helpers

public enum CodeSigningInfo {
    /// Team identifier from this process' own code signature, nil when ad-hoc / unsigned.
    public static func ownTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any],
              let team = dict[kSecCodeInfoTeamIdentifier as String] as? String,
              !team.isEmpty,
              team.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return team
    }

    /// Requirement the peer must satisfy: identifier + Apple anchor + same team (when we have one).
    public static func peerRequirement(identifier: String) -> String {
        if let team = ownTeamIdentifier() {
            return "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        }
        return "identifier \"\(identifier)\""
    }
}
