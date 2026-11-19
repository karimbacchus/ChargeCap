//
// HelperClient.swift
// ChargeCap (forked from AlDente Helper.swift)
//
// MIT License
//

import AppKit
import ChargeCapCore
import Combine
import Foundation
import IOKit.pwr_mgt

@MainActor
public final class HelperClient: ObservableObject {
    public static let shared = HelperClient()

    @Published public private(set) var isHelperConnected: Bool = false
    @Published public private(set) var helperStatusMessage: String = "Checking helper…"
    @Published public private(set) var helperNeedsUpdate: Bool = false
    @Published public private(set) var installedHelperVersion: String?
    @Published public private(set) var detectedKeyFamily: SMCKeyFamily = SMCKeyFamily.detect()
    @Published public private(set) var sleepAssertionActive: Bool = false
    @Published public private(set) var lastAppliedCommand: HardwareCommand?

    private static let targetBinary = "/Library/PrivilegedHelperTools/com.chargecap.app.helper"
    private static let targetPlist = "/Library/LaunchDaemons/com.chargecap.app.helper.plist"

    private var xpcConnection: NSXPCConnection?
    private var localSleepAssertionID: IOPMAssertionID = 0

    /// What the helper has actually been sent (reset on disconnect so the next apply re-sends everything).
    private var sentCommand: HardwareCommand?
    private var sentLED: UInt8?
    private var sentClassicLimit: UInt8?

    private init() {
        detectedKeyFamily = SMCKeyFamily.detect()
    }

    // MARK: - Connection

    private func connection() -> NSXPCConnection {
        if let existing = xpcConnection {
            return existing
        }
        let conn = NSXPCConnection(
            machServiceName: ChargeCapConstants.helperMachServiceName,
            options: .privileged
        )
        conn.remoteObjectInterface = NSXPCInterface(with: HelperToolProtocol.self)
        // Only talk to our own signed helper.
        conn.setCodeSigningRequirement(
            CodeSigningInfo.peerRequirement(identifier: ChargeCapConstants.helperMachServiceName)
        )
        conn.invalidationHandler = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.xpcConnection = nil
                self.markDisconnected()
            }
        }
        conn.interruptionHandler = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.markDisconnected()
                // launchd (KeepAlive) restarts the helper; re-check shortly.
                try? await Task.sleep(nanoseconds: 800_000_000)
                self.checkHelperStatus()
            }
        }
        conn.resume()
        self.xpcConnection = conn
        return conn
    }

    private func markDisconnected() {
        isHelperConnected = false
        sentCommand = nil
        sentLED = nil
        sentClassicLimit = nil
    }

    private func dropConnection() {
        xpcConnection?.invalidate()
        xpcConnection = nil
        markDisconnected()
    }

    private func proxy() -> HelperToolProtocol? {
        connection().remoteObjectProxyWithErrorHandler { [weak self] _ in
            Task { @MainActor in
                // Force a fresh send of everything on the next apply.
                self?.sentCommand = nil
                self?.sentLED = nil
                self?.sentClassicLimit = nil
            }
        } as? HelperToolProtocol
    }

    // MARK: - Status

    public func checkHelperStatus() {
        let bundled = ChargeCapConstants.helperVersion
        if geteuid() == 0 {
            isHelperConnected = true
            installedHelperVersion = bundled
            helperNeedsUpdate = false
            helperStatusMessage = "Running with root SMC access (\(detectedKeyFamily.rawValue))"
            return
        }

        let remote = connection().remoteObjectProxyWithErrorHandler { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isHelperConnected = false
                self.installedHelperVersion = nil
                self.helperNeedsUpdate = false
                self.helperStatusMessage = "Privileged SMC Helper not running (Read-Only Telemetry)"
            }
        } as? HelperToolProtocol

        remote?.getVersion { [weak self] version in
            Task { @MainActor in
                guard let self else { return }
                let wasConnected = self.isHelperConnected
                self.installedHelperVersion = version
                if version == bundled {
                    self.isHelperConnected = true
                    self.helperNeedsUpdate = false
                    self.helperStatusMessage = "Helper v\(version) active · \(self.detectedKeyFamily.rawValue)"
                    if !wasConnected {
                        // (Re)connected: make sure the next apply re-sends everything.
                        self.sentCommand = nil
                        self.sentLED = nil
                        self.sentClassicLimit = nil
                    }
                } else {
                    self.isHelperConnected = false
                    self.helperNeedsUpdate = true
                    self.helperStatusMessage = "Helper update required (installed v\(version), bundled v\(bundled))"
                }
            }
        }
    }

    // MARK: - Install / uninstall

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Runs a shell command with administrator privileges. Returns nil on success, else an error message.
    private func runAdminShell(_ shellCmd: String) -> String? {
        let source = "do shell script \"\(Self.appleScriptEscape(shellCmd))\" with administrator privileges"
        guard let script = NSAppleScript(source: source) else { return "Could not create install script" }
        var errorDict: NSDictionary?
        script.executeAndReturnError(&errorDict)
        if let errorDict {
            return (errorDict[NSAppleScript.errorMessage] as? String) ?? "Authorization cancelled or failed"
        }
        return nil
    }

    /// Installs or updates the privileged helper via an administrator prompt.
    public func installOrUpdateHelper() {
        guard let helperSourceURL = Bundle.main.url(forAuxiliaryExecutable: "ChargeCapHelper")
            ?? Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("ChargeCapHelper") else {
            helperStatusMessage = "ChargeCapHelper binary not found in bundle"
            return
        }

        let binary = Self.targetBinary
        let plist = Self.targetPlist
        let plistContent = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
            + "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">"
            + "<plist version=\"1.0\"><dict>"
            + "<key>Label</key><string>\(ChargeCapConstants.helperMachServiceName)</string>"
            + "<key>MachServices</key><dict><key>\(ChargeCapConstants.helperMachServiceName)</key><true/></dict>"
            + "<key>ProgramArguments</key><array><string>\(binary)</string></array>"
            + "<key>RunAtLoad</key><true/><key>KeepAlive</key><true/>"
            + "</dict></plist>"

        let q = Self.shellQuote
        let shellCmd = [
            "mkdir -p /Library/PrivilegedHelperTools",
            "launchctl bootout system \(q(plist)) 2>/dev/null || true",
            "cp -f \(q(helperSourceURL.path)) \(q(binary))",
            "chown root:wheel \(q(binary))",
            "chmod 755 \(q(binary))",
            "printf '%s\\n' \(q(plistContent)) > \(q(plist))",
            "chown root:wheel \(q(plist))",
            "chmod 644 \(q(plist))",
            "launchctl bootstrap system \(q(plist))"
        ].joined(separator: " && ")

        if let error = runAdminShell(shellCmd) {
            helperStatusMessage = "Helper installation failed: \(error)"
            return
        }
        dropConnection()
        installedHelperVersion = nil
        helperStatusMessage = "Helper installed, connecting…"
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            self.checkHelperStatus()
        }
    }

    public func uninstallHelper() {
        let q = Self.shellQuote
        let shellCmd = [
            "launchctl bootout system \(q(Self.targetPlist)) 2>/dev/null || true",
            "rm -f \(q(Self.targetBinary)) \(q(Self.targetPlist))"
        ].joined(separator: " && ")
        if let error = runAdminShell(shellCmd) {
            helperStatusMessage = "Helper uninstall failed: \(error)"
            return
        }
        dropConnection()
        installedHelperVersion = nil
        helperNeedsUpdate = false
        helperStatusMessage = "Helper uninstalled"
    }

    // MARK: - Hardware control

    private static let directWriter: SMCChargeControl.Writer = { key, bytes in
        (try? SMCKit.writeBytes(key: key, bytes: bytes)) != nil
    }

    /// Applies the desired hardware state. Deduped against what was last sent; `force` re-sends everything.
    public func apply(_ command: HardwareCommand, force: Bool = false) {
        // Dev / self-test mode must never reach the SMC, pmset or the helper.
        guard !Prefs.devMode else { return }
        updateSleepAssertion(command)

        let isRoot = geteuid() == 0
        guard isRoot || isHelperConnected else {
            // Nothing can be sent right now; leave sent-state empty so we send once connected.
            return
        }

        let hwChanged = force || sentCommand == nil
            || sentCommand?.chargingEnabled != command.chargingEnabled
            || sentCommand?.forceDischarge != command.forceDischarge
        let ledChanged = command.magSafeLED != nil && (force || command.magSafeLED != sentLED)

        defer { lastAppliedCommand = command }
        guard hwChanged || ledChanged else { return }

        let ledByte: UInt8 = ledChanged
            ? (command.magSafeLED ?? SMCChargeControl.ledUntouched)
            : SMCChargeControl.ledUntouched

        if isRoot {
            if hwChanged {
                _ = SMCChargeControl.applyState(
                    chargingEnabled: command.chargingEnabled,
                    forceDischarge: command.forceDischarge,
                    ledByte: ledByte,
                    write: Self.directWriter
                )
            } else if ledChanged, let led = command.magSafeLED {
                _ = SMCChargeControl.setMagSafeLED(led, write: Self.directWriter)
            }
        } else {
            guard let remote = proxy() else { return }
            if hwChanged {
                remote.applyState(
                    chargingEnabled: command.chargingEnabled,
                    forceDischarge: command.forceDischarge,
                    ledByte: ledByte
                ) { _, _ in }
            } else if ledChanged, let led = command.magSafeLED {
                remote.setSMCBytes(key: "ACLC", bytes: [led]) { _ in }
            }
        }

        if hwChanged { sentCommand = command }
        if ledChanged { sentLED = command.magSafeLED }
    }

    public func setClassicMaxCharge(_ value: UInt8) {
        // Dev / self-test mode must never reach the SMC, pmset or the helper.
        guard !Prefs.devMode else { return }
        guard value != sentClassicLimit else { return }
        if geteuid() == 0 {
            _ = SMCChargeControl.setMaxBatteryCharge(value, write: Self.directWriter)
            sentClassicLimit = value
        } else if isHelperConnected, let remote = proxy() {
            remote.setMaxBatteryCharge(value) { _ in }
            sentClassicLimit = value
        }
    }

    public func setLowPowerMode(_ enabled: Bool, scope: PowerSourceScope) {
        // Dev / self-test mode must never reach the SMC, pmset or the helper.
        guard !Prefs.devMode else { return }
        if geteuid() == 0 {
            let flag = scope == .all ? "-a" : (scope == .battery ? "-b" : "-c")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            p.arguments = [flag, "lowpowermode", enabled ? "1" : "0"]
            try? p.run()
            p.waitUntilExit()
            return
        }
        guard isHelperConnected, let remote = proxy() else { return }
        remote.setLowPowerMode(enabled: enabled, scope: scope.rawValue) { [weak self] ok, message in
            if !ok {
                Task { @MainActor in self?.helperStatusMessage = "Low Power Mode change failed: \(message)" }
            }
        }
    }

    /// Synchronous (≤ ~1.5 s) cleanup for app termination.
    public func restoreOnQuit(keepChargeInhibited: Bool) {
        // Dev / self-test mode must never reach the SMC, pmset or the helper.
        guard !Prefs.devMode else { return }
        releaseSleepAssertion()

        if geteuid() == 0 {
            if keepChargeInhibited {
                _ = SMCChargeControl.applyState(
                    chargingEnabled: false, forceDischarge: false,
                    ledByte: SMCChargeControl.ledUntouched, write: Self.directWriter
                )
            } else {
                _ = SMCChargeControl.setForceDischarge(false, write: Self.directWriter)
                _ = SMCChargeControl.setCharging(true, write: Self.directWriter)
                _ = SMCChargeControl.setMagSafeLED(0x00, write: Self.directWriter)
            }
            return
        }
        guard isHelperConnected || xpcConnection != nil else { return }

        let semaphore = DispatchSemaphore(value: 0)
        let syncProxy = connection().synchronousRemoteObjectProxyWithErrorHandler { _ in
            semaphore.signal()
        } as? HelperToolProtocol
        guard let syncProxy else { return }
        let keep = keepChargeInhibited
        nonisolated(unsafe) let remote = syncProxy
        DispatchQueue.global(qos: .userInitiated).async {
            if keep {
                remote.applyState(
                    chargingEnabled: false, forceDischarge: false,
                    ledByte: SMCChargeControl.ledUntouched
                ) { _, _ in semaphore.signal() }
            } else {
                remote.resetAll { _ in semaphore.signal() }
            }
        }
        _ = semaphore.wait(timeout: .now() + 1.5)
        sentCommand = nil
        sentLED = nil
    }

    // MARK: - Sleep assertion (in-process)

    private func updateSleepAssertion(_ command: HardwareCommand) {
        if command.preventSleep {
            guard localSleepAssertionID == 0 else { return }
            var id: IOPMAssertionID = 0
            let res = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                command.preventSleepReason as CFString,
                &id
            )
            if res == kIOReturnSuccess {
                localSleepAssertionID = id
                sleepAssertionActive = true
            }
        } else {
            releaseSleepAssertion()
        }
    }

    private func releaseSleepAssertion() {
        guard localSleepAssertionID != 0 else { return }
        IOPMAssertionRelease(localSleepAssertionID)
        localSleepAssertionID = 0
        sleepAssertionActive = false
    }

    // MARK: - Diagnostics (read-only)

    public func readSMCDiagnostics() -> [(key: String, type: String, hex: String)] {
        var rows: [(key: String, type: String, hex: String)] = []
        for key in SMCChargeControl.diagnosticKeys {
            guard let info = try? SMCKit.keyInformation(key) else {
                rows.append((key, "—", "absent"))
                continue
            }
            let hex: String
            if let bytes = try? SMCKit.readBytes(key: key) {
                hex = bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
            } else {
                hex = "unreadable"
            }
            rows.append((key, info.type.toString().trimmingCharacters(in: .whitespaces), hex))
        }
        return rows
    }
}
