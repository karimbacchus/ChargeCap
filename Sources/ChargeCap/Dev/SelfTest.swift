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

        print("=== ChargeCap Self-Test Suite (macOS 27) ===")

        // 1. Live Hardware SMC & Battery Telemetry Test
        let liveSnap = BatteryTelemetryReader.readSnapshot()
        print("Live Telemetry: OS=\(liveSnap.osPercentage)% HW=\(String(format: "%.1f%%", liveSnap.hardwarePercentage)) Temp=\(String(format: "%.1fC", liveSnap.batteryTemperatureC)) Voltage=\(String(format: "%.2fV", liveSnap.voltageVolts)) Cells=\(liveSnap.cellVoltagesMillivolts) Adapter=\(liveSnap.adapterName)")
        check((0...100).contains(liveSnap.osPercentage), "Live OS battery percentage in 0...100")
        check(liveSnap.voltageVolts > 5.0 && liveSnap.voltageVolts < 25.0, "Live battery pack voltage valid (\(liveSnap.voltageVolts)V)")
        check(liveSnap.batteryTemperatureC > 5.0 && liveSnap.batteryTemperatureC < 85.0, "Live battery temperature valid (\(liveSnap.batteryTemperatureC)C)")

        let keyFamily = SMCKeyFamily.detect()
        print("Detected SMC Key Family: \(keyFamily.rawValue)")
        check(!keyFamily.rawValue.isEmpty, "SMC key family detected")

        // 2. State Machine Verification
        let controller = ChargeController.shared
        let prefs = Prefs.shared

        prefs.chargeLimit = 80
        prefs.sailingModeEnabled = true
        prefs.sailingDelta = 5
        prefs.heatProtectionEnabled = true
        prefs.heatProtectionMaxCelsius = 35.0
        prefs.autoDischargeEnabled = false
        controller.isTopUpActive = false
        controller.isManualDischargeActive = false
        controller.stopCalibration()

        // 2a. Charging when below Sailing target (70% < 75%)
        var mock = BatterySnapshot.placeholder
        mock.osPercentage = 70
        mock.hardwarePercentage = 70.0
        mock.batteryTemperatureC = 30.0
        mock.isPluggedIn = true
        controller.evaluateWithSnapshot(mock)
        check(controller.operatingMode == .chargingToLimit(target: 80), "Charges when below sailing range (70% -> 80%)")

        // 2b. Holding at limit when at 80%
        mock.osPercentage = 80
        mock.hardwarePercentage = 80.0
        controller.evaluateWithSnapshot(mock)
        check(controller.operatingMode == .holdingAtLimit(limit: 80), "Holds at limit when reaching 80%")

        // 2c. Sailing when at 77% (between 75% and 80%) after holding
        mock.osPercentage = 77
        mock.hardwarePercentage = 77.0
        controller.evaluateWithSnapshot(mock)
        check(controller.operatingMode == .sailing(lowerBound: 75, upperBound: 80), "Sails without micro-charging at 77% (75-80% window)")

        // 2d. Heat Protection pause when battery temperature >= 35.0 C
        mock.batteryTemperatureC = 37.5
        controller.evaluateWithSnapshot(mock)
        if case .heatProtectionPaused = controller.operatingMode {
            check(true, "Heat Protection pauses charging at 37.5°C")
        } else {
            check(false, "Heat Protection pauses charging at 37.5°C (got \(controller.operatingMode))")
        }

        // Cool down to 31.0 C
        mock.batteryTemperatureC = 31.0
        controller.evaluateWithSnapshot(mock)
        check(!controller.isHeatPaused, "Heat Protection clears after 2°C hysteresis cooldown")

        // 2e. Top Up override
        controller.isTopUpActive = true
        controller.evaluateWithSnapshot(mock)
        check(controller.operatingMode == .topUp, "Top Up overrides limit to charge toward 100%")
        controller.isTopUpActive = false

        // 2f. Automatic Discharge when above limit (92% > 80%)
        prefs.autoDischargeEnabled = true
        mock.osPercentage = 92
        mock.hardwarePercentage = 92.0
        controller.evaluateWithSnapshot(mock)
        check(controller.operatingMode == .discharging(target: 80, automatic: true), "Auto-Discharge activates at 92% when limit is 80%")
        prefs.autoDischargeEnabled = false

        // 2g. 5-Step Calibration Mode progression
        controller.startCalibration()
        mock.osPercentage = 85
        controller.evaluateWithSnapshot(mock)
        check(controller.operatingMode == .calibrating(.chargeToFullFirst), "Calibration Step 1 (Charge to 100%)")

        mock.osPercentage = 100
        controller.evaluateWithSnapshot(mock)
        check(controller.operatingMode == .calibrating(.dischargeTo15), "Calibration auto-advances to Step 2 (Discharge to 15%)")

        mock.osPercentage = 15
        controller.evaluateWithSnapshot(mock)
        check(controller.operatingMode == .calibrating(.chargeToFullSecond), "Calibration auto-advances to Step 3 (Recharge to 100%)")

        mock.osPercentage = 100
        controller.evaluateWithSnapshot(mock)
        check(controller.operatingMode == .calibrating(.holdAt100), "Calibration auto-advances to Step 4 (Hold at 100%)")

        controller.advanceCalibrationStep()
        check(controller.operatingMode == .calibrating(.restoreToLimit), "Calibration advances to Step 5 (Restore to Limit)")

        mock.osPercentage = 80
        controller.evaluateWithSnapshot(mock)
        check(!controller.isCalibrating, "Calibration completes and restores normal limit at 80%")

        // 3. URL Scheme Automation Tests
        check(URLCommands.handle(URL(string: "chargecap://set-limit?percent=75")!), "URL scheme sets limit to 75%")
        check(prefs.chargeLimit == 75, "Charge limit updated to 75% via URL")
        check(URLCommands.handle(URL(string: "chargecap://magsafe?mode=green")!), "URL scheme sets MagSafe LED mode")
        check(prefs.magSafeLEDMode == .green, "MagSafe LED mode updated to .green")
        prefs.magSafeLEDMode = .auto
        prefs.chargeLimit = 80
        prefs.heatProtectionMaxCelsius = 40.0

        // Restore live snapshot before rendering UI
        controller.refreshNow()

        // 4. Render Liquid Glass UI Snapshots for Visual Inspection
        for tab in PopoverTab.allCases {
            let view = PopoverView(initialTab: tab)
                .environment(\.colorScheme, .dark)
            let filename = "popover-\(tab.rawValue.lowercased().replacingOccurrences(of: " ", with: "-")).png"
            let ok = await renderWindowToPNG(view, size: CGSize(width: 430, height: 610), to: outputDirectory.appendingPathComponent(filename))
            check(ok, "Rendered Liquid Glass Popover (\(tab.rawValue)) to \(filename)")
        }

        let settingsSnapshotOK = await renderWindowToPNG(
            SettingsView().environment(\.colorScheme, .dark),
            size: CGSize(width: 580, height: 470),
            to: outputDirectory.appendingPathComponent("settings.png")
        )
        check(settingsSnapshotOK, "Rendered SettingsView to settings.png")

        print("=== Self-Test Finished: \(failures.isEmpty ? "ALL PASSED" : "\(failures.count) FAILED") ===")
        return failures.isEmpty
    }

    private static func renderWindowToPNG<V: View>(_ view: V, size: CGSize, to url: URL) async -> Bool {
        let hosting = NSHostingView(rootView: view)
        let fitting = hosting.fittingSize
        let finalSize = CGSize(
            width: max(size.width, fitting.width),
            height: max(size.height, fitting.height)
        )
        hosting.frame = NSRect(origin: .zero, size: finalSize)

        let window = NSWindow(
            contentRect: NSRect(x: 120, y: 120, width: finalSize.width, height: finalSize.height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = NSColor(calibratedRed: 0.08, green: 0.11, blue: 0.16, alpha: 1.0)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = hosting
        window.orderFrontRegardless()
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
