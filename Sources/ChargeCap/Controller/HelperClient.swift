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
    @Published public private(set) var helperNeedsUpdate: Bool = false
    @Published public private(set) var installedHelperVersion: String?
    @Published public private(set) var detectedKeyFamily: SMCKeyFamily = SMCKeyFamily.detect()
    @Published public private(set) var sleepAssertionActive: Bool = false
    @Published public private(set) var lastAppliedCommand: HardwareCommand?

    /// True while the daemon is registered but the user has not yet approved it in Login Items.
    @Published public private(set) var needsApproval: Bool = false

    private var service: SMAppService { SMAppService.daemon(plistName: ChargeCapConstants.daemonPlistName) }
    private var approvalPollTask: Task<Void, Never>?
    private var legacyCleanupAttempted = false
    private var activeObserver: NSObjectProtocol?

    private var xpcConnection: NSXPCConnection?
    private var localSleepAssertionID: IOPMAssertionID = 0

    /// What the helper has actually been sent (reset on disconnect so the next apply re-sends everything).
    private var sentCommand: HardwareCommand?
    private var sentLED: UInt8?
    private var sentClassicLimit: UInt8?

    private init() {
        detectedKeyFamily = SMCKeyFamily.detect()
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.needsApproval else { return }
                self.refreshAfterApprovalCheck()
            }
        }
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
            CodeSigningInfo.peerRequirement(identifier: ChargeCapConstants.helperSigningIdentifier)
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

    /// Dev-mode only (self-test / README screenshots): presents a healthy, connected helper in the UI.
    /// Opens no XPC connection and touches no hardware; every write path still early-returns in dev mode.
    public func simulateConnectedForScreenshots() {
        guard Prefs.devMode else { return }
        simulatedForScreenshots = true
        needsApproval = false
        isHelperConnected = true
        helperNeedsUpdate = false
        installedHelperVersion = ChargeCapConstants.helperVersion
        helperStatusMessage = "Helper v\(ChargeCapConstants.helperVersion) active · \(detectedKeyFamily.rawValue)"
    }

    private var simulatedForScreenshots = false

    public func checkHelperStatus() {
        if simulatedForScreenshots && Prefs.devMode { return }
        let bundled = ChargeCapConstants.helperVersion
        if geteuid() == 0 {
            isHelperConnected = true
            installedHelperVersion = bundled
            helperNeedsUpdate = false
            helperStatusMessage = "Running with root SMC access (\(detectedKeyFamily.rawValue))"
            return
        }

        switch service.status {
        case .notRegistered, .notFound:
            needsApproval = false
            isHelperConnected = false
            installedHelperVersion = nil
            helperNeedsUpdate = false
            helperStatusMessage = "Helper not installed"
            return
        case .requiresApproval:
            isHelperConnected = false
            installedHelperVersion = nil
            helperNeedsUpdate = false
            markNeedsApproval()
            return
        default:
            needsApproval = false
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
                    self.cleanUpLegacyHelperIfNeeded()
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

    private static let approvalMessage = "Approve ChargeCap in System Settings \u{203A} Login Items (Touch ID works)"

    private func markNeedsApproval() {
        needsApproval = true
        helperStatusMessage = Self.approvalMessage
    }

    /// Removes the old /Library helper (via the new root daemon) once per launch.
    private func cleanUpLegacyHelperIfNeeded() {
        guard !legacyCleanupAttempted else { return }
        let fm = FileManager.default
        guard fm.fileExists(atPath: ChargeCapConstants.legacyHelperPlistPath)
            || fm.fileExists(atPath: ChargeCapConstants.legacyHelperBinaryPath) else { return }
        legacyCleanupAttempted = true
        guard let remote = proxy() else { return }
        remote.removeLegacyHelper { ok, message in
            NSLog("ChargeCap: legacy helper cleanup ok=\(ok): \(message)")
        }
    }

    /// Registers (or re-registers, if outdated) the daemon with SMAppService; approval happens in Login Items.
    public func installOrUpdateHelper() {
        guard !Prefs.devMode else { return }
        approvalPollTask?.cancel()
        approvalPollTask = nil

        if service.status == .enabled {
            // Re-register so launchd picks up the bundled (newer) helper binary.
            try? service.unregister()
        }
        dropConnection()
        installedHelperVersion = nil
        legacyCleanupAttempted = false

        do {
            try service.register()
        } catch {
            // register() also throws when approval is still required; the status tells the two apart.
            if service.status == .requiresApproval {
                // handled below
            } else if service.status != .enabled {
                helperStatusMessage = "Helper installation failed: \(error.localizedDescription)"
                return
            }
        }

        switch service.status {
        case .enabled:
            needsApproval = false
            helperStatusMessage = "Helper installed, connecting…"
            scheduleConnectCheck()
        case .requiresApproval:
            markNeedsApproval()
            SMAppService.openSystemSettingsLoginItems()
            startApprovalPolling()
        default:
            needsApproval = false
            helperStatusMessage = "Helper registration did not complete (is ChargeCap in /Applications?)"
        }
    }

    private func scheduleConnectCheck() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 800_000_000)
            self.checkHelperStatus()
        }
    }

    private func startApprovalPolling() {
        approvalPollTask?.cancel()
        approvalPollTask = Task { @MainActor [weak self] in
            for _ in 0..<180 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if Task.isCancelled { return }
                guard let self else { return }
                if self.service.status == .enabled {
                    self.refreshAfterApprovalCheck()
                    return
                }
            }
        }
    }

    /// Called when the app regains focus or polling notices a status change.
    private func refreshAfterApprovalCheck() {
        if service.status == .enabled {
            approvalPollTask?.cancel()
            approvalPollTask = nil
            needsApproval = false
            dropConnection()
            helperStatusMessage = "Helper approved, connecting…"
            scheduleConnectCheck()
        }
    }

    public func uninstallHelper() {
        guard !Prefs.devMode else { return }
        approvalPollTask?.cancel()
        approvalPollTask = nil

        let fm = FileManager.default
        let legacyPresent = fm.fileExists(atPath: ChargeCapConstants.legacyHelperPlistPath)
            || fm.fileExists(atPath: ChargeCapConstants.legacyHelperBinaryPath)
        if legacyPresent, isHelperConnected, let remote = proxy() {
            remote.removeLegacyHelper { _, _ in }
        }

        Task { @MainActor in
            if legacyPresent, self.isHelperConnected {
                // Give the daemon a moment to finish before it is unregistered.
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            do {
                try await self.service.unregister()
            } catch {
                self.helperStatusMessage = "Helper uninstall failed: \(error.localizedDescription)"
                return
            }
            self.dropConnection()
            self.installedHelperVersion = nil
            self.helperNeedsUpdate = false
            self.needsApproval = false
            self.helperStatusMessage = "Helper uninstalled"
        }
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
        if simulatedForScreenshots && Prefs.devMode {
            return [("CHTE", "ui32", "00 00 00 00"), ("CHIE", "hex_", "00"), ("ACLC", "ui8 ", "03"), ("CH0C", "hex_", "00")]
        }
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
