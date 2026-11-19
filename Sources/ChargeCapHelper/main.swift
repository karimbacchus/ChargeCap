//
// main.swift
// ChargeCapHelper (forked from com.davidwernhart.Helper)
//
// MIT License
//

import AppKit
import ChargeCapCore
import Foundation

public final class HelperTool: NSObject, HelperToolProtocol {
    public static let instance = HelperTool()

    /// Serialises all SMC access (XPC calls arrive on arbitrary threads).
    private let opLock = NSRecursiveLock()
    private let lock = NSLock()
    private var modifiedKeys: [String: [UInt8]] = [:]

    private lazy var writer: SMCChargeControl.Writer = { [unowned self] key, bytes in
        self.writeKey(key, bytes: bytes)
    }

    public func getVersion(withReply reply: @escaping (String) -> Void) {
        reply(ChargeCapConstants.helperVersion)
    }

    public func applyState(chargingEnabled: Bool, forceDischarge: Bool, ledByte: UInt8, withReply reply: @escaping (Bool, String) -> Void) {
        opLock.lock()
        let result = SMCChargeControl.applyState(
            chargingEnabled: chargingEnabled,
            forceDischarge: forceDischarge,
            ledByte: ledByte,
            write: writer
        )
        opLock.unlock()
        reply(result.ok, result.summary)
    }

    public func setLowPowerMode(enabled: Bool, scope: String, withReply reply: @escaping (Bool, String) -> Void) {
        guard let parsed = PowerSourceScope(rawValue: scope) else {
            reply(false, "Invalid power source scope")
            return
        }
        let flag: String
        switch parsed {
        case .all: flag = "-a"
        case .battery: flag = "-b"
        case .adapter: flag = "-c"
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = [flag, "lowpowermode", enabled ? "1" : "0"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            reply(false, "pmset failed to launch: \(error.localizedDescription)")
            return
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        reply(process.terminationStatus == 0, output)
    }

    public func setMaxBatteryCharge(_ setVal: UInt8, withReply reply: @escaping (Bool) -> Void) {
        opLock.lock()
        let ok = SMCChargeControl.setMaxBatteryCharge(setVal, write: writer)
        opLock.unlock()
        reply(ok)
    }

    public func setSMCBytes(key: String, bytes: [UInt8], withReply reply: @escaping (Bool) -> Void) {
        guard SMCChargeControl.writableKeys.contains(key), bytes.count <= 4 else {
            reply(false)
            return
        }
        opLock.lock()
        let ok = writeKey(key, bytes: bytes)
        opLock.unlock()
        reply(ok)
    }

    public func readSMCBytes(key: String, withReply reply: @escaping ([UInt8]) -> Void) {
        guard SMCChargeControl.readableKeys.contains(key) else {
            reply([])
            return
        }
        opLock.lock()
        let bytes = (try? SMCKit.readBytes(key: key)) ?? []
        opLock.unlock()
        reply(bytes)
    }

    public func resetAll(withReply reply: @escaping (Bool) -> Void) {
        opLock.lock()
        lock.lock()
        let savedKeys = modifiedKeys
        modifiedKeys.removeAll()
        lock.unlock()

        for (key, originalBytes) in savedKeys {
            try? SMCKit.writeBytes(key: key, bytes: originalBytes)
        }
        // Explicitly ensure charging is enabled and discharge is off
        SMCChargeControl.setForceDischarge(false, write: writer)
        SMCChargeControl.setCharging(true, write: writer)
        if SMCKit.isKeyFound("ACLC") {
            try? SMCKit.writeBytes(key: "ACLC", bytes: [0x00])
        }
        opLock.unlock()
        reply(true)
    }

    // MARK: - CLI one-shot helpers (not part of the XPC protocol)

    func cliSetCharging(_ enabled: Bool) -> (Bool, String) {
        opLock.lock(); defer { opLock.unlock() }
        let r = SMCChargeControl.setCharging(enabled, write: writer)
        return (r.ok, r.keys.isEmpty ? "No writable SMC charge key matched" : r.keys.joined(separator: ","))
    }

    func cliSetForceDischarge(_ discharge: Bool) -> (Bool, String) {
        opLock.lock(); defer { opLock.unlock() }
        let r = SMCChargeControl.setForceDischarge(discharge, write: writer)
        return (r.ok, r.keys.isEmpty ? "No writable SMC discharge key matched" : r.keys.joined(separator: ","))
    }

    func cliSetLED(_ value: UInt8) -> Bool {
        opLock.lock(); defer { opLock.unlock() }
        return SMCChargeControl.setMagSafeLED(value, write: writer)
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
        // Only the signed ChargeCap app (same team as this helper) may connect.
        let requirement = CodeSigningInfo.peerRequirement(identifier: ChargeCapConstants.appBundleIdentifier)
        newConnection.setCodeSigningRequirement(requirement)
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
    let (ok, msg) = HelperTool.instance.cliSetCharging(enable)
    print("setChargingEnabled(\(enable)): ok=\(ok) keys=\(msg)")
    exit(ok ? 0 : 1)
} else if let idx = args.firstIndex(of: "--force-discharge"), idx + 1 < args.count {
    let discharge = (args[idx + 1] == "1" || args[idx + 1] == "true")
    let (ok, msg) = HelperTool.instance.cliSetForceDischarge(discharge)
    print("setForceDischarge(\(discharge)): ok=\(ok) keys=\(msg)")
    exit(ok ? 0 : 1)
} else if let idx = args.firstIndex(of: "--magsafe-led"), idx + 1 < args.count, let val = UInt8(args[idx + 1]) {
    let ok = HelperTool.instance.cliSetLED(val)
    print("setMagSafeLED(\(val)): ok=\(ok)")
    exit(ok ? 0 : 1)
} else if args.contains("--reset") {
    HelperTool.instance.resetAll { _ in }
    exit(0)
}

let delegate = HelperXPCDelegate()
let listener = NSXPCListener(machServiceName: ChargeCapConstants.helperMachServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
