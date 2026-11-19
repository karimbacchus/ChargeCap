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

/// Borderless windows refuse key status by default, which makes SwiftUI render controls as inactive (grey).
private final class KeyableWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
public enum SelfTest {
    /// Regenerate the README screenshots (and all self-test renders) with one command:
    ///   build/ChargeCap.app/Contents/MacOS/ChargeCap --selftest build/selftest --screenshots docs/screenshots
    /// (or `make screenshots`). Hardware-free: dev mode never reaches the SMC or the helper.
    public static func run(outputDirectory: URL, screenshotsDirectory: URL? = nil) async -> Bool {
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
        // Plugged in, 80% with an 80% limit, healthy helper: the canonical screenshot state.
        HelperClient.shared.simulateConnectedForScreenshots()
        ChargeController.shared.evaluateWithSnapshot(.placeholder)

        // 4. Render Liquid Glass UI Snapshots for Visual Inspection
        seedPopoverHistory()
        // A regular (not accessory) app activates reliably, which keeps controls tinted in renders.
        NSApp.setActivationPolicy(.regular)
        for tab in PopoverTab.allCases {
            for dark in [true, false] {
                let scheme = dark ? "dark" : "light"
                let filename = "popover-\(tab.rawValue)-\(scheme).png"
                let height: CGFloat = tab == .everything ? 1700 : (tab == .graphs ? 1000 : PopoverView.preferredSize.height)
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

        // 5. Curated README set.
        if let shots = screenshotsDirectory {
            try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
            let curated: [(String, String)] = [
                ("popover-overview-dark.png", "popover-dark.png"), ("popover-overview-light.png", "popover-light.png"),
                ("popover-graphs-dark.png", "popover-graphs.png"),
                ("settings-charging.png", "settings-charging.png"), ("settings-battery-care.png", "settings-battery-care.png"),
                ("settings-schedule.png", "settings-schedule.png"), ("settings-menu-bar.png", "settings-menu-bar.png"),
                ("onboarding-1.png", "onboarding-1.png"), ("menubar-icons.png", "menubar-icons.png")
            ]
            for (src, dst) in curated {
                let to = shots.appendingPathComponent(dst)
                try? FileManager.default.removeItem(at: to)
                let ok = (try? FileManager.default.copyItem(at: outputDirectory.appendingPathComponent(src), to: to)) != nil
                check(ok, "Copied \(dst) to \(shots.path)")
            }
        }

        print("=== Self-Test Finished: \(failures.isEmpty ? "ALL PASSED" : "\(failures.count) FAILED") ===")
        return failures.isEmpty
    }

    /// Synthetic 7 days of plausible usage (dev store, in memory only): unplugged for a few hours
    /// on weekdays, recharged to the 80% limit, then held there while plugged in.
    private static func seedPopoverHistory() {
        let now = Date()
        let step: TimeInterval = 600
        let count = 7 * 144
        var percent = 80.0
        var out: [HistorySample] = []
        let cal = Calendar.current
        for i in 0..<count {
            let t = now.addingTimeInterval(-Double(count - 1 - i) * step)
            let hour = Double(cal.component(.hour, from: t)) + Double(cal.component(.minute, from: t)) / 60
            let day = cal.component(.day, from: t)
            // Slightly different unplug window each day.
            let start = 9.5 + Double(day % 3) * 0.75
            let unplugged = hour >= start && hour < start + 4.5 + Double(day % 2)
            let load = unplugged ? 9 + 5 * abs(sin(Double(i) / 4)) : 6 + 3 * abs(sin(Double(i) / 9))
            var charging = false
            var adapter = 0.0
            var battery = 0.0
            if unplugged {
                percent = max(35, percent - load / 60 * 100 * 10 / 60 * 0.9)
                battery = -load
            } else if percent < 79.5 {
                charging = true
                percent = min(80, percent + 4.5)
                adapter = load + 38
                battery = 38
            } else {
                percent = 80 - (i % 23 == 0 ? 1 : 0)
                adapter = load + 0.5
            }
            let temp = 29.5 + load * 0.25 + (charging ? 3 : 0) + sin(Double(i) / 6)
            out.append(HistorySample(
                timestamp: t, percent: Int(percent.rounded()), hwPercent: percent, temperatureC: temp,
                batteryW: battery, systemW: load, adapterW: adapter, isCharging: charging,
                isPluggedIn: !unplugged, limit: 80))
        }
        var health: [HealthSample] = []
        let today = cal.startOfDay(for: now)
        for d in 0..<30 {
            let day = cal.date(byAdding: .day, value: -(29 - d), to: today) ?? today
            health.append(HealthSample(day: day, fullChargeCapacityMah: 8882 + (29 - d) / 6 * 12, designCapacityMah: 8532,
                                       healthPercent: 100, cycleCount: 11 - (29 - d) / 5))
        }
        HistoryStore.shared.replaceForScreenshots(samples: out, health: health)
    }

    private static func captureOwnWindow(_ window: NSWindow) -> CGImage? {
        typealias Fn = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let fn = unsafeBitCast(sym, to: Fn.self)
        let optionIncludingWindow: UInt32 = 1 << 3
        let boundsIgnoreFraming: UInt32 = 1 << 0
        let bestResolution: UInt32 = 1 << 3
        return fn(.null, optionIncludingWindow, UInt32(window.windowNumber), boundsIgnoreFraming | bestResolution)?.takeRetainedValue()
    }

    private static func renderWindowToPNG<V: View>(_ view: V, size: CGSize, dark: Bool = true, to url: URL) async -> Bool {
        let hosting = NSHostingView(rootView: view)
        let finalSize = size
        hosting.frame = NSRect(origin: .zero, size: finalSize)

        let window = KeyableWindow(
            contentRect: NSRect(x: 120, y: 120, width: finalSize.width, height: finalSize.height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = dark ? NSColor(calibratedRed: 0.08, green: 0.11, blue: 0.16, alpha: 1.0) : NSColor(calibratedRed: 0.93, green: 0.94, blue: 0.96, alpha: 1.0)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        // Make this window key (and the app active) so controls render in their active, tinted state.
        for _ in 0..<20 {
            NSApp.activate(ignoringOtherApps: true)
            NSRunningApplication.current.activate(options: [.activateAllWindows])
            window.orderOut(nil)
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .milliseconds(300))
            if window.isKeyWindow && NSApp.isActive { break }
        }
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try? await Task.sleep(for: .milliseconds(150))
        if !(window.isKeyWindow && NSApp.isActive) { print("    [warn] \(url.lastPathComponent) rendered while inactive; re-run for tinted controls") }

        try? FileManager.default.removeItem(at: url)
        defer { window.orderOut(nil) }

        // Preferred: composite the real window (glass + active controls). Capturing a window owned by
        // this process needs no Screen Recording permission. CGWindowListCreateImage is marked
        // unavailable in the macOS 15+ SDK, so it is resolved dynamically; falls back to cacheDisplay.
        if let image = captureOwnWindow(window), let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
           (try? png.write(to: url)) != nil {
            return true
        }

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
