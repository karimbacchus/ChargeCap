//
// SelfTest.swift
// ChargeCap
//
// MIT License
//

import AppKit
import ChargeCapCore
import Foundation
import SwiftUI

@MainActor
public enum SelfTest {
    public static func run(outputDirectory: URL) async -> Bool {
        try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        var failures: [String] = []

        func check(_ condition: Bool, _ name: String) {
            if condition {
                print("  [PASS] \(name)")
            } else {
                print("  [FAIL] \(name)")
                failures.append(name)
            }
        }

        print("=== ChargeCap Self-Test Suite (macOS 27, hardware-free) ===")

        // SAFETY: nothing below may reach the SMC, the helper or pmset. HelperClient refuses all
        // writes while Prefs.devMode is true (set by --selftest); verify that precondition first.
        check(Prefs.devMode, "Dev mode active (HelperClient writes disabled)")
        guard Prefs.devMode else { return false }

        // 1. Live telemetry (read-only).
        let liveSnap = BatteryTelemetryReader.readSnapshot()
        print("Live Telemetry: OS=\(liveSnap.osPercentage)% HW=\(String(format: "%.1f%%", liveSnap.hardwarePercentage)) Temp=\(String(format: "%.1fC", liveSnap.batteryTemperatureC)) Voltage=\(String(format: "%.2fV", liveSnap.voltageVolts)) Cells=\(liveSnap.cellVoltagesMillivolts) Adapter=\(liveSnap.adapterName)")
        check((0...100).contains(liveSnap.osPercentage), "Live OS battery percentage in 0...100")
        check(liveSnap.voltageVolts > 5.0 && liveSnap.voltageVolts < 25.0, "Live battery pack voltage valid (\(liveSnap.voltageVolts)V)")
        check(liveSnap.batteryTemperatureC > 5.0 && liveSnap.batteryTemperatureC < 85.0, "Live battery temperature valid (\(liveSnap.batteryTemperatureC)C)")
        let keyFamily = SMCKeyFamily.detect()
        print("Detected SMC Key Family: \(keyFamily.rawValue)")
        check(!keyFamily.rawValue.isEmpty, "SMC key family detected")

        // 2. Policy scenarios (pure ChargePolicy, no controller, no hardware).
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func input(_ pct: Int, temp: Double = 30, limit: Int = 80, previous: OperatingMode = .holdingAtLimit(limit: 80),
                   now: Date = t0, _ configure: (inout PolicyInput) -> Void = { _ in }) -> PolicyOutput {
            var s = BatterySnapshot.placeholder
            s.osPercentage = pct
            s.hardwarePercentage = Double(pct)
            s.batteryTemperatureC = temp
            s.isPluggedIn = true
            s.isCharging = false
            s.isFullyCharged = false
            var i = PolicyInput(snapshot: s, limit: limit, sailingEnabled: true, sailingLowerBound: 75,
                                heatEnabled: true, heatMaxC: 35, previousMode: previous, now: now)
            configure(&i)
            return ChargePolicy.evaluate(i)
        }

        check(input(70).mode == .chargingToLimit(target: 80), "Charges when below sailing range (70% -> 80%)")
        check(input(80).mode == .holdingAtLimit(limit: 80), "Holds at limit when reaching 80%")
        check(input(77).mode == .sailing(lowerBound: 75, upperBound: 80), "Sails without micro-charging at 77%")
        check(input(77, previous: .chargingToLimit(target: 80)).mode == .chargingToLimit(target: 80), "Keeps charging through the sailing band")
        if case .heatProtectionPaused = input(70, temp: 37.5).mode {
            check(true, "Heat Protection pauses charging at 37.5°C")
        } else {
            check(false, "Heat Protection pauses charging at 37.5°C")
        }
        check(input(70, temp: 31, now: t0.addingTimeInterval(120)) { $0.heatPausedSince = t0 }.isHeatPaused, "Heat Protection holds for the 5 minute minimum")
        check(!input(70, temp: 31, now: t0.addingTimeInterval(301)) { $0.heatPausedSince = t0 }.isHeatPaused, "Heat Protection clears after cooldown")
        check(input(70) { $0.topUpActive = true }.mode == .topUp, "Top Up overrides limit")
        check(input(92) { $0.autoDischarge = true }.mode == .discharging(target: 80, automatic: true), "Auto-Discharge at 92% (limit 80%)")
        check(input(92) { $0.autoDischarge = true; $0.lidClosed = true }.command.forceDischarge == false, "Auto-Discharge disabled with lid closed")
        check(input(90, previous: .holdingAtLimit(limit: 80)) { $0.manualDischargeActive = true }.command.forceDischarge, "Manual discharge forces discharge")
        check(!input(90) { $0.manualDischargeActive = true; $0.lidClosed = true }.command.forceDischarge, "Manual discharge pauses with lid closed")

        var cal = input(85) { $0.calibrationPhase = .chargeToFullFirst }
        check(cal.mode == .calibrating(.chargeToFullFirst), "Calibration step 1 (charge to 100%)")
        cal = input(100) { $0.calibrationPhase = .chargeToFullFirst }
        check(cal.mode == .calibrating(.dischargeTo10), "Calibration advances to step 2 (discharge to 10%)")
        cal = input(10) { $0.calibrationPhase = .dischargeTo10 }
        check(cal.mode == .calibrating(.chargeToFullSecond), "Calibration advances to step 3 (recharge)")
        cal = input(100) { $0.calibrationPhase = .chargeToFullSecond }
        check(cal.mode == .calibrating(.holdAt100), "Calibration advances to step 4 (hold)")
        cal = input(80) { $0.calibrationPhase = .restoreToLimit }
        check(cal.calibrationPhase == nil && cal.events.contains(.calibrationFinished), "Calibration finishes at the limit")

        // 3. URL scheme automation (dev-mode preferences only; HelperClient refuses hardware writes).
        let prefs = Prefs.shared
        check(URLCommands.handle(URL(string: "chargecap://set-limit?percent=75")!), "URL scheme sets limit to 75%")
        check(prefs.chargeLimit == 75, "Charge limit updated to 75% via URL")
        check(URLCommands.handle(URL(string: "chargecap://magsafe?mode=green")!), "URL scheme sets MagSafe LED mode")
        check(prefs.magSafeLEDMode == .green, "MagSafe LED mode updated to .green")
        prefs.magSafeLEDMode = .auto
        prefs.chargeLimit = 80

        // Render the views with placeholder data (no live hardware state).
        ChargeController.shared.evaluateWithSnapshot(.placeholder)

        // 4. Render Liquid Glass UI Snapshots for Visual Inspection
        seedPopoverHistory()
        for tab in PopoverTab.allCases {
            for dark in [true, false] {
                let scheme = dark ? "dark" : "light"
                let filename = "popover-\(tab.rawValue)-\(scheme).png"
                let height: CGFloat = tab == .everything ? 1700 : PopoverView.preferredSize.height
                let ok = await renderWindowToPNG(
                    PopoverView(initialTab: tab).environment(\.colorScheme, dark ? .dark : .light),
                    size: CGSize(width: PopoverView.preferredSize.width, height: height),
                    dark: dark,
                    to: outputDirectory.appendingPathComponent(filename))
                check(ok, "Rendered Liquid Glass Popover (\(tab.rawValue), \(scheme)) to \(filename)")
            }
        }

        for section in SettingsSection.allCases {
            let fname = "settings-\(section.rawValue.lowercased().replacingOccurrences(of: " ", with: "-")).png"
            let ok = await renderWindowToPNG(
                SettingsView(initialSection: section),
                size: CGSize(width: 820, height: 600),
                to: outputDirectory.appendingPathComponent(fname)
            )
            check(ok, "Rendered SettingsView (\(section.rawValue)) to \(fname)")
        }

        for (idx, _) in OnboardingView.Step.allCases.enumerated() {
            let fname = "onboarding-\(idx + 1).png"
            let ok = await renderWindowToPNG(
                OnboardingView(initialStep: idx),
                size: OnboardingView.preferredSize,
                to: outputDirectory.appendingPathComponent(fname)
            )
            check(ok, "Rendered OnboardingView step \(idx + 1) to \(fname)")
        }

        // Menu bar icon variants: every style x several operating modes, light and dark.
        do {
            let modes: [(String, OperatingMode)] = [
                ("charging", .chargingToLimit(target: 80)), ("holding", .holdingAtLimit(limit: 80)),
                ("sailing", .sailing(lowerBound: 75, upperBound: 80)), ("discharging", .discharging(target: 80, automatic: false)),
                ("heat", .heatProtectionPaused(tempC: 38, maxC: 35)), ("calibrating", .calibrating(.dischargeTo10)),
                ("battery", .onBattery)
            ]
            var snap = BatterySnapshot.placeholder
            snap.osPercentage = 64
            let previousTint = prefs.menuBarLowPowerTint
            prefs.menuBarLowPowerTint = true
            defer { prefs.menuBarLowPowerTint = previousTint }
            let ok = await renderWindowToPNG(
                MenuBarIconGallery(snapshot: snap, modes: modes),
                size: CGSize(width: 760, height: 330),
                to: outputDirectory.appendingPathComponent("menubar-icons.png")
            )
            check(ok, "Rendered menu bar icon gallery to menubar-icons.png")
        }

        print("=== Self-Test Finished: \(failures.isEmpty ? "ALL PASSED" : "\(failures.count) FAILED") ===")
        return failures.isEmpty
    }

    /// Synthetic 24 h of samples (dev store only) so the graphs have something to draw.
    private static func seedPopoverHistory() {
        let store = HistoryStore.shared
        guard store.samples.count < 2 else { return }
        let now = Date()
        for i in 0..<144 {
            var snap = BatterySnapshot.placeholder
            let t = Double(i) / 143
            snap.osPercentage = Int(45 + 35 * abs(sin(t * 5)))
            snap.batteryTemperatureC = 30 + 6 * sin(t * 7)
            snap.systemLoadWatts = 8 + 6 * abs(sin(t * 11))
            snap.adapterInputWatts = i % 40 < 25 ? 30 + 10 * sin(t * 9) : 0
            snap.batteryPowerWatts = snap.adapterInputWatts - snap.systemLoadWatts
            store.record(snapshot: snap, limit: 80, now: now.addingTimeInterval(-86_400 + Double(i) * 600))
        }
        for d in 0..<30 {
            var snap = BatterySnapshot.placeholder
            snap.fullChargeCapacityMah = 6000 - d / 3 * 10
            snap.healthPercentage = 97 - Double(d) / 15
            snap.cycleCount = 120 + d * 2
            store.recordHealth(snapshot: snap, now: now.addingTimeInterval(-Double(30 - d) * 86_400))
        }
    }

    private static func renderWindowToPNG<V: View>(_ view: V, size: CGSize, dark: Bool = true, to url: URL) async -> Bool {
        let hosting = NSHostingView(rootView: view)
        let finalSize = size
        hosting.frame = NSRect(origin: .zero, size: finalSize)

        let window = NSWindow(
            contentRect: NSRect(x: 120, y: 120, width: finalSize.width, height: finalSize.height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = dark ? NSColor(calibratedRed: 0.08, green: 0.11, blue: 0.16, alpha: 1.0) : NSColor(calibratedRed: 0.93, green: 0.94, blue: 0.96, alpha: 1.0)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()

        try? await Task.sleep(for: .milliseconds(180))

        let winID = window.windowNumber
        try? FileManager.default.removeItem(at: url)

        if winID > 0 {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            proc.arguments = ["-x", "-o", "-l", "\(winID)", url.path]
            try? proc.run()
            proc.waitUntilExit()
            if FileManager.default.fileExists(atPath: url.path) {
                window.orderOut(nil)
                return true
            }
        }
        window.orderOut(nil)

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return false }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        guard let pngData = rep.representation(using: .png, properties: [:]) else { return false }
        do {
            try pngData.write(to: url)
            return true
        } catch {
            return false
        }
    }
}
