//
// main.swift
// ChargeCapHelper (forked from com.davidwernhart.Helper)
//
// MIT License
//

import AppKit
import ChargeCapCore
import Foundation
import IOKit.pwr_mgt

public final class HelperTool: NSObject, HelperToolProtocol {
    public static let instance = HelperTool()

    private let lock = NSLock()
    private var modifiedKeys: [String: [UInt8]] = [:]
    private var openAssertions: [IOPMAssertionID] = []

    public func getVersion(withReply reply: @escaping (String) -> Void) {
        reply(ChargeCapConstants.helperVersion)
    }

    public func setChargingEnabled(_ enabled: Bool, withReply reply: @escaping (Bool, String) -> Void) {
        var appliedKeys: [String] = []
        var anySuccess = false

        // 1. Modern Apple Silicon M3/M4/M5 / macOS 27 keys (CHIB, CHIC, CHCE, CHCC)
        if SMCKit.isKeyFound("CHIB") {
            if writeKey("CHIB", bytes: [enabled ? 0x00 : 0x02]) {
                appliedKeys.append("CHIB")
                anySuccess = true
            }
        }
        if SMCKit.isKeyFound("CHIC") {
            if writeKey("CHIC", bytes: [enabled ? 0x00 : 0x02]) {
                appliedKeys.append("CHIC")
                anySuccess = true
            }
        }
        if SMCKit.isKeyFound("CHCE") {
            if writeKey("CHCE", bytes: [enabled ? 0x01 : 0x00]) {
                appliedKeys.append("CHCE")
                anySuccess = true
            }
        }
        if SMCKit.isKeyFound("CHCC") {
            if writeKey("CHCC", bytes: [enabled ? 0x01 : 0x00]) {
                appliedKeys.append("CHCC")
                anySuccess = true
            }
        }

        // 2. Apple Silicon CHTE (4-byte UInt32)
        if SMCKit.isKeyFound("CHTE") {
            let bytes: [UInt8] = enabled ? [0x00, 0x00, 0x00, 0x00] : [0x01, 0x00, 0x00, 0x00]
            if writeKey("CHTE", bytes: bytes) {
                appliedKeys.append("CHTE")
                anySuccess = true
            }
        }

        // 3. Apple Silicon M1/M2 legacy keys (CH0B, CH0C)
        if SMCKit.isKeyFound("CH0B") {
            if writeKey("CH0B", bytes: [enabled ? 0x00 : 0x02]) {
                appliedKeys.append("CH0B")
                anySuccess = true
            }
        }
        if SMCKit.isKeyFound("CH0C") {
            if writeKey("CH0C", bytes: [enabled ? 0x00 : 0x02]) {
                appliedKeys.append("CH0C")
                anySuccess = true
            }
        }

        // If enabling charging, also ensure force-discharge is off
        if enabled {
            if SMCKit.isKeyFound("CHIE") {
                _ = writeKey("CHIE", bytes: [0x00])
            }
            if SMCKit.isKeyFound("CH0I") {
                _ = writeKey("CH0I", bytes: [0x00])
            }
            if SMCKit.isKeyFound("CH0J") {
                _ = writeKey("CH0J", bytes: [0x00])
            }
        }

        let summary = appliedKeys.isEmpty ? "No writable SMC charge key matched" : appliedKeys.joined(separator: ",")
        reply(anySuccess, summary)
    }

    public func setForceDischarge(_ discharge: Bool, withReply reply: @escaping (Bool, String) -> Void) {
        var appliedKeys: [String] = []
        var anySuccess = false

        if discharge {
            // Inhibit charging first before isolating adapter
            setChargingEnabled(false) { _, _ in }
        }

        if SMCKit.isKeyFound("CHIE") {
            if writeKey("CHIE", bytes: [discharge ? 0x08 : 0x00]) {
                appliedKeys.append("CHIE")
                anySuccess = true
            }
        }
        if SMCKit.isKeyFound("CH0I") {
            if writeKey("CH0I", bytes: [discharge ? 0x01 : 0x00]) {
                appliedKeys.append("CH0I")
                anySuccess = true
            }
        }
        if SMCKit.isKeyFound("CH0J") {
            if writeKey("CH0J", bytes: [discharge ? 0x01 : 0x00]) {
                appliedKeys.append("CH0J")
                anySuccess = true
            }
        }

        let summary = appliedKeys.isEmpty ? "No writable SMC discharge key matched" : appliedKeys.joined(separator: ",")
        reply(anySuccess, summary)
    }

    public func setMagSafeLED(_ value: UInt8, withReply reply: @escaping (Bool) -> Void) {
        guard SMCKit.isKeyFound("ACLC") else {
            reply(false)
            return
        }
        let ok = writeKey("ACLC", bytes: [value])
        reply(ok)
    }

    public func setMaxBatteryCharge(_ setVal: UInt8, withReply reply: @escaping (Bool) -> Void) {
        var ok = false
        if SMCKit.isKeyFound("BCLM") {
            ok = writeKey("BCLM", bytes: [setVal]) || ok
        }
        if SMCKit.isKeyFound("BFCL") {
            ok = writeKey("BFCL", bytes: [setVal]) || ok
        }
        reply(ok)
    }

    public func setSMCBytes(key: String, bytes: [UInt8], withReply reply: @escaping (Bool) -> Void) {
        let ok = writeKey(key, bytes: bytes)
        reply(ok)
    }

    public func readSMCBytes(key: String, withReply reply: @escaping ([UInt8]) -> Void) {
        let bytes = (try? SMCKit.readBytes(key: key)) ?? []
        reply(bytes)
    }

    public func createAssertion(assertion: String, reason: String, withReply reply: @escaping (IOPMAssertionID) -> Void) {
        var assertionID: IOPMAssertionID = 0
        let cfAssertion = assertion as CFString
        let cfReason = reason as CFString
        let success = IOPMAssertionCreateWithName(
            cfAssertion,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            cfReason,
            &assertionID
        )
        if success == kIOReturnSuccess {
            lock.lock()
            openAssertions.append(assertionID)
            lock.unlock()
            reply(assertionID)
        } else {
            reply(0)
        }
    }

    public func releaseAssertion(assertionID: IOPMAssertionID) {
        guard assertionID != 0 else { return }
        IOPMAssertionRelease(assertionID)
        lock.lock()
        openAssertions.removeAll { $0 == assertionID }
        lock.unlock()
    }

    public func resetAll(withReply reply: @escaping (Bool) -> Void) {
        lock.lock()
        let savedKeys = modifiedKeys
        let assertions = openAssertions
        modifiedKeys.removeAll()
        openAssertions.removeAll()
        lock.unlock()

        for (key, originalBytes) in savedKeys {
            try? SMCKit.writeBytes(key: key, bytes: originalBytes)
        }
        // Explicitly ensure charging is enabled and discharge is off
        setForceDischarge(false) { _, _ in }
        setChargingEnabled(true) { _, _ in }
        if SMCKit.isKeyFound("ACLC") {
            try? SMCKit.writeBytes(key: "ACLC", bytes: [0x00])
        }
        for id in assertions {
            IOPMAssertionRelease(id)
        }
        reply(true)
    }

    private func writeKey(_ key: String, bytes: [UInt8]) -> Bool {
        do {
            try SMCKit.ensureOpen()
            lock.lock()
            let alreadySaved = (modifiedKeys[key] != nil)
            lock.unlock()
            if !alreadySaved, let original = try? SMCKit.readBytes(key: key) {
                lock.lock()
                modifiedKeys[key] = original
                lock.unlock()
            }
            try SMCKit.writeBytes(key: key, bytes: bytes)
            return true
        } catch {
            return false
        }
    }
}

final class HelperXPCDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: HelperToolProtocol.self)
        newConnection.exportedObject = HelperTool.instance
        newConnection.resume()
        return true
    }
}

// Support one-shot CLI operations when invoked with flags, or run XPC Mach listener daemon
let args = CommandLine.arguments
if args.contains("--version") {
    print(ChargeCapConstants.helperVersion)
    exit(0)
} else if let idx = args.firstIndex(of: "--enable-charging"), idx + 1 < args.count {
    let enable = (args[idx + 1] == "1" || args[idx + 1] == "true")
    var success = false
    HelperTool.instance.setChargingEnabled(enable) { ok, msg in
        print("setChargingEnabled(\(enable)): ok=\(ok) keys=\(msg)")
        success = ok
    }
    exit(success ? 0 : 1)
} else if let idx = args.firstIndex(of: "--force-discharge"), idx + 1 < args.count {
    let discharge = (args[idx + 1] == "1" || args[idx + 1] == "true")
    var success = false
    HelperTool.instance.setForceDischarge(discharge) { ok, msg in
        print("setForceDischarge(\(discharge)): ok=\(ok) keys=\(msg)")
        success = ok
    }
    exit(success ? 0 : 1)
} else if let idx = args.firstIndex(of: "--magsafe-led"), idx + 1 < args.count, let val = UInt8(args[idx + 1]) {
    var success = false
    HelperTool.instance.setMagSafeLED(val) { ok in
        print("setMagSafeLED(\(val)): ok=\(ok)")
        success = ok
    }
    exit(success ? 0 : 1)
} else if args.contains("--reset") {
    HelperTool.instance.resetAll { _ in }
    exit(0)
}

let delegate = HelperXPCDelegate()
let listener = NSXPCListener(machServiceName: ChargeCapConstants.helperMachServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
