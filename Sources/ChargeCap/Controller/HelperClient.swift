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
import ServiceManagement

@MainActor
public final class HelperClient: ObservableObject {
    public static let shared = HelperClient()

    @Published public private(set) var isHelperConnected: Bool = false
    @Published public private(set) var helperStatusMessage: String = "Checking helper…"
    @Published public private(set) var detectedKeyFamily: SMCKeyFamily = SMCKeyFamily.detect()
    @Published public private(set) var sleepAssertionActive: Bool = false

    private var xpcConnection: NSXPCConnection?
    private var localSleepAssertionID: IOPMAssertionID = 0

    private init() {
        detectedKeyFamily = SMCKeyFamily.detect()
    }

    private func connection() -> NSXPCConnection {
        if let existing = xpcConnection {
            return existing
        }
        let conn = NSXPCConnection(
            machServiceName: ChargeCapConstants.helperMachServiceName,
            options: .privileged
        )
        conn.remoteObjectInterface = NSXPCInterface(with: HelperToolProtocol.self)
        conn.invalidationHandler = { [weak self] in
            Task { @MainActor in
                self?.xpcConnection = nil
                self?.isHelperConnected = false
            }
        }
        conn.interruptionHandler = { [weak self] in
            Task { @MainActor in
                self?.isHelperConnected = false
            }
        }
        conn.resume()
        self.xpcConnection = conn
        return conn
    }

    public func checkHelperStatus() {
        if geteuid() == 0 {
            isHelperConnected = true
            helperStatusMessage = "Running with root SMC access (\(detectedKeyFamily.rawValue))"
            return
        }

        let proxy = connection().remoteObjectProxyWithErrorHandler { [weak self] _ in
            Task { @MainActor in
                self?.isHelperConnected = false
                self?.helperStatusMessage = "Privileged SMC Helper not running (Read-Only Telemetry)"
            }
        } as? HelperToolProtocol

        proxy?.getVersion { [weak self] version in
            Task { @MainActor in
                guard let self else { return }
                if version == ChargeCapConstants.helperVersion {
                    self.isHelperConnected = true
                    self.helperStatusMessage = "Helper v\(version) active · \(self.detectedKeyFamily.rawValue)"
                } else {
                    self.isHelperConnected = false
                    self.helperStatusMessage = "Helper version mismatch (v\(version) vs v\(ChargeCapConstants.helperVersion))"
                }
            }
        }
    }

    public func installHelper() {
        // 1. Try modern SMAppService daemon registration first if bundled in /Applications
        let service = SMAppService.daemon(plistName: ChargeCapConstants.helperDaemonPlistName)
        do {
            try service.register()
            checkHelperStatus()
            if isHelperConnected {
                return
            }
        } catch {
            // Fall through to privileged administrator installation script
        }

        installHelperWithAdminPrompt()
    }

    public func installHelperWithAdminPrompt() {
        guard let helperSourceURL = Bundle.main.url(forAuxiliaryExecutable: "ChargeCapHelper")
            ?? Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("ChargeCapHelper") else {
            helperStatusMessage = "ChargeCapHelper binary not found in bundle"
            return
        }

        let targetBinary = "/Library/PrivilegedHelperTools/com.chargecap.app.helper"
        let targetPlist = "/Library/LaunchDaemons/com.chargecap.app.helper.plist"

        let plistContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>com.chargecap.app.helper</string>
            <key>MachServices</key>
            <dict>
                <key>com.chargecap.app.helper</key>
                <true/>
            </dict>
            <key>ProgramArguments</key>
            <array>
                <string>/Library/PrivilegedHelperTools/com.chargecap.app.helper</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
        </dict>
        </plist>
        """

        let tempPlist = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("com.chargecap.app.helper.plist")
        try? plistContent.write(to: tempPlist, atomically: true, encoding: .utf8)

        let shellCmd = [
            "mkdir -p /Library/PrivilegedHelperTools",
            "cp -f '\(helperSourceURL.path)' '\(targetBinary)'",
            "chown root:wheel '\(targetBinary)'",
            "chmod 755 '\(targetBinary)'",
            "cp -f '\(tempPlist.path)' '\(targetPlist)'",
            "chown root:wheel '\(targetPlist)'",
            "chmod 644 '\(targetPlist)'",
            "launchctl bootout system '\(targetPlist)' 2>/dev/null || true",
            "launchctl bootstrap system '\(targetPlist)'"
        ].joined(separator: " && ")

        let appleScriptSource = "do shell script \"\(shellCmd.replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        if let script = NSAppleScript(source: appleScriptSource) {
            var errorDict: NSDictionary?
            script.executeAndReturnError(&errorDict)
            if errorDict == nil {
                xpcConnection?.invalidate()
                xpcConnection = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    self.checkHelperStatus()
                }
            } else {
                helperStatusMessage = "Helper installation cancelled or failed"
            }
        }
    }

    public func uninstallHelper() {
        let targetBinary = "/Library/PrivilegedHelperTools/com.chargecap.app.helper"
        let targetPlist = "/Library/LaunchDaemons/com.chargecap.app.helper.plist"
        let shellCmd = [
            "launchctl bootout system '\(targetPlist)' 2>/dev/null || true",
            "rm -f '\(targetBinary)' '\(targetPlist)'"
        ].joined(separator: " && ")
        let appleScriptSource = "do shell script \"\(shellCmd.replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        if let script = NSAppleScript(source: appleScriptSource) {
            var errorDict: NSDictionary?
            script.executeAndReturnError(&errorDict)
            xpcConnection?.invalidate()
            xpcConnection = nil
            isHelperConnected = false
            helperStatusMessage = "Helper uninstalled"
        }
    }

    public func setChargingEnabled(_ enabled: Bool) {
        if isHelperConnected {
            let proxy = connection().remoteObjectProxyWithErrorHandler { _ in } as? HelperToolProtocol
            proxy?.setChargingEnabled(enabled) { [weak self] ok, _ in
                if ok {
                    Task { @MainActor in self?.isHelperConnected = true }
                }
            }
        } else {
            // Attempt direct SMC write if running with sufficient permissions
            tryDirectSetCharging(enabled)
        }
    }

    public func setForceDischarge(_ discharge: Bool) {
        if isHelperConnected {
            let proxy = connection().remoteObjectProxyWithErrorHandler { _ in } as? HelperToolProtocol
            proxy?.setForceDischarge(discharge) { [weak self] ok, _ in
                if ok {
                    Task { @MainActor in self?.isHelperConnected = true }
                }
            }
        } else {
            tryDirectSetDischarge(discharge)
        }
    }

    public func setMagSafeLED(_ byte: UInt8) {
        if isHelperConnected {
            let proxy = connection().remoteObjectProxyWithErrorHandler { _ in } as? HelperToolProtocol
            proxy?.setMagSafeLED(byte) { _ in }
        } else {
            try? SMCKit.writeBytes(key: "ACLC", bytes: [byte])
        }
    }

    public func setClassicMaxCharge(_ value: UInt8) {
        if isHelperConnected {
            let proxy = connection().remoteObjectProxyWithErrorHandler { _ in } as? HelperToolProtocol
            proxy?.setMaxBatteryCharge(value) { _ in }
        } else {
            try? SMCKit.writeBytes(key: "BCLM", bytes: [value])
        }
    }

    public func setPreventSleep(_ prevent: Bool, reason: String = "ChargeCap Active Battery Control") {
        if prevent {
            guard localSleepAssertionID == 0 else { return }
            var id: IOPMAssertionID = 0
            let res = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                reason as CFString,
                &id
            )
            if res == kIOReturnSuccess {
                localSleepAssertionID = id
                sleepAssertionActive = true
            }
        } else {
            guard localSleepAssertionID != 0 else { return }
            IOPMAssertionRelease(localSleepAssertionID)
            localSleepAssertionID = 0
            sleepAssertionActive = false
        }
    }

    public func resetAllOnExit() {
        setPreventSleep(false)
        if isHelperConnected {
            let proxy = connection().remoteObjectProxyWithErrorHandler { _ in } as? HelperToolProtocol
            proxy?.resetAll { _ in }
        } else {
            tryDirectSetDischarge(false)
            tryDirectSetCharging(true)
        }
    }

    private func tryDirectSetCharging(_ enabled: Bool) {
        if SMCKit.isKeyFound("CHIB") {
            try? SMCKit.writeBytes(key: "CHIB", bytes: [enabled ? 0x00 : 0x02])
        }
        if SMCKit.isKeyFound("CHIC") {
            try? SMCKit.writeBytes(key: "CHIC", bytes: [enabled ? 0x00 : 0x02])
        }
        if SMCKit.isKeyFound("CHCE") {
            try? SMCKit.writeBytes(key: "CHCE", bytes: [enabled ? 0x01 : 0x00])
        }
        if SMCKit.isKeyFound("CHTE") {
            try? SMCKit.writeBytes(key: "CHTE", bytes: enabled ? [0, 0, 0, 0] : [1, 0, 0, 0])
        }
        if SMCKit.isKeyFound("CH0B") {
            try? SMCKit.writeBytes(key: "CH0B", bytes: [enabled ? 0x00 : 0x02])
        }
    }

    private func tryDirectSetDischarge(_ discharge: Bool) {
        if SMCKit.isKeyFound("CHIE") {
            try? SMCKit.writeBytes(key: "CHIE", bytes: [discharge ? 0x08 : 0x00])
        }
        if SMCKit.isKeyFound("CH0I") {
            try? SMCKit.writeBytes(key: "CH0I", bytes: [discharge ? 0x01 : 0x00])
        }
    }
}
