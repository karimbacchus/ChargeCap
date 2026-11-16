//
// ChargeCapApp.swift
// ChargeCap (forked from AlDente AppDelegate.swift)
//
// MIT License
//

import AppKit
import ChargeCapCore
import Combine
import SwiftUI

@main
struct ChargeCapMain {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--status") {
            let snap = BatteryTelemetryReader.readSnapshot()
            print(String(
                format: "ChargeCap Status: %d%% (HW: %.1f%%) | PluggedIn: %@ | Charging: %@ | Temp: %.1f°C | Adapter: %.1fW | System: %.1fW | Battery: %+.1fW | Health: %.1f%% (%d cycles)",
                snap.osPercentage,
                snap.hardwarePercentage,
                snap.isPluggedIn ? "Yes" : "No",
                snap.isCharging ? "Yes" : "No",
                snap.batteryTemperatureC,
                snap.adapterInputWatts,
                snap.systemLoadWatts,
                snap.batteryPowerWatts,
                snap.healthPercentage,
                snap.cycleCount
            ))
            exit(0)
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarItem: NSStatusItem!
    private var popover: NSPopover!
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        func value(after flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { args.dropFirst($0 + 1).first }
        }

        if args.contains("--selftest") {
            let outDir = URL(fileURLWithPath: value(after: "--selftest") ?? "build/selftest")
            Task { @MainActor in
                let ok = await SelfTest.run(outputDirectory: outDir)
                exit(ok ? 0 : 1)
            }
            return
        }

        if let limitStr = value(after: "--set-limit"), let val = Int(limitStr), (10...100).contains(val) {
            ChargeController.shared.setChargeLimit(val)
        }

        setupPopoverAndStatusItem()
        ChargeController.shared.startMonitoring()
        ScheduleManager.shared.startScheduler()

        if args.contains("--open-popover") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.showPopover()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        ChargeController.shared.handleAppTermination()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            URLCommands.handle(url)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func setupPopoverAndStatusItem() {
        let rootView = PopoverView { [weak self] in
            self?.openSettingsWindow()
        }

        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = true
        pop.contentViewController = NSHostingController(rootView: rootView)
        self.popover = pop

        statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusBarItem.button {
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        updateStatusBarButton()

        // Reactively update menu bar icon & readout whenever telemetry or prefs change
        ChargeController.shared.objectWillChange
            .merge(with: Prefs.shared.objectWillChange)
            .debounce(for: .milliseconds(80), scheduler: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateStatusBarButton()
            }
            .store(in: &cancellables)
    }

    private func updateStatusBarButton() {
        guard let button = statusBarItem?.button else { return }
        let controller = ChargeController.shared
        let prefs = Prefs.shared

        if prefs.menuBarIconStyle == .textOnly {
            button.image = nil
            let text = MenuBarIconRenderer.readoutText(snapshot: controller.snapshot, prefs: prefs)
            button.title = text.isEmpty ? "\(controller.snapshot.osPercentage)%" : text
        } else {
            button.image = MenuBarIconRenderer.renderStatusBarImage(
                snapshot: controller.snapshot,
                mode: controller.operatingMode,
                prefs: prefs
            )
            let readout = MenuBarIconRenderer.readoutText(snapshot: controller.snapshot, prefs: prefs)
            button.title = readout.isEmpty ? "" : " \(readout)"
        }
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            showQuickContextMenu()
            return
        }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        ChargeController.shared.refreshNow()
        guard let button = statusBarItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    private func showQuickContextMenu() {
        let controller = ChargeController.shared
        let prefs = Prefs.shared
        let menu = NSMenu()

        let statusItem = NSMenuItem(
            title: "\(controller.snapshot.osPercentage)% (HW \(String(format: "%.1f%%", controller.snapshot.hardwarePercentage))) · \(controller.operatingMode.badgeText)",
            action: nil,
            keyEquivalent: ""
        )
        statusItem.isEnabled = false
        menu.addItem(statusItem)
        menu.addItem(.separator())

        for preset in prefs.quickPresets {
            let item = NSMenuItem(title: "Set Charge Limit to \(preset)%", action: #selector(selectPreset(_:)), keyEquivalent: "")
            item.tag = preset
            item.target = self
            item.state = (prefs.chargeLimit == preset && !controller.isTopUpActive) ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let topUpItem = NSMenuItem(title: "Top Up to 100%", action: #selector(toggleTopUpAction), keyEquivalent: "t")
        topUpItem.target = self
        topUpItem.state = controller.isTopUpActive ? .on : .off
        menu.addItem(topUpItem)

        let dischargeItem = NSMenuItem(title: "Discharge to \(prefs.chargeLimit)%", action: #selector(toggleDischargeAction), keyEquivalent: "d")
        dischargeItem.target = self
        dischargeItem.state = controller.isManualDischargeActive ? .on : .off
        menu.addItem(dischargeItem)

        let sailingItem = NSMenuItem(title: "Sailing Mode (-\(prefs.sailingDelta)%)", action: #selector(toggleSailingAction), keyEquivalent: "s")
        sailingItem.target = self
        sailingItem.state = prefs.sailingModeEnabled ? .on : .off
        menu.addItem(sailingItem)

        let calibrateItem = NSMenuItem(
            title: controller.isCalibrating ? "Stop Calibration Mode" : "Start Calibration Mode",
            action: #selector(toggleCalibrationAction),
            keyEquivalent: ""
        )
        calibrateItem.target = self
        calibrateItem.state = controller.isCalibrating ? .on : .off
        menu.addItem(calibrateItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettingsWindow), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(title: "Quit ChargeCap", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusBarItem.menu = menu
        statusBarItem.button?.performClick(nil)
        statusBarItem.menu = nil
    }

    @objc private func selectPreset(_ sender: NSMenuItem) {
        ChargeController.shared.isTopUpActive = false
        ChargeController.shared.setChargeLimit(sender.tag)
    }

    @objc private func toggleTopUpAction() {
        ChargeController.shared.toggleTopUp()
    }

    @objc private func toggleDischargeAction() {
        ChargeController.shared.toggleManualDischarge()
    }

    @objc private func toggleSailingAction() {
        Prefs.shared.sailingModeEnabled.toggle()
    }

    @objc private func toggleCalibrationAction() {
        if ChargeController.shared.isCalibrating {
            ChargeController.shared.stopCalibration()
        } else {
            ChargeController.shared.startCalibration()
        }
    }

    @objc private func openSettingsWindow() {
        popover?.performClose(nil)
        if settingsWindow == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 430),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            win.title = "ChargeCap Settings"
            win.contentView = NSHostingView(rootView: SettingsView())
            win.center()
            win.isReleasedWhenClosed = false
            self.settingsWindow = win
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
