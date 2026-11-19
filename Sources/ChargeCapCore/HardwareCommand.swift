//
// HardwareCommand.swift
// ChargeCapCore
//
// MIT License
//

import Foundation

/// The complete desired hardware state, applied to the helper in one round trip.
public struct HardwareCommand: Equatable, Sendable {
    public var chargingEnabled: Bool
    public var forceDischarge: Bool
    /// nil = don't touch the MagSafe LED.
    public var magSafeLED: UInt8?
    public var preventSleep: Bool
    public var preventSleepReason: String

    public init(
        chargingEnabled: Bool,
        forceDischarge: Bool,
        magSafeLED: UInt8?,
        preventSleep: Bool,
        preventSleepReason: String = "ChargeCap"
    ) {
        self.chargingEnabled = chargingEnabled
        self.forceDischarge = forceDischarge
        self.magSafeLED = magSafeLED
        self.preventSleep = preventSleep
        self.preventSleepReason = preventSleepReason
    }
}

public enum PowerSourceScope: String, Codable, Sendable {
    case all, battery, adapter
}
