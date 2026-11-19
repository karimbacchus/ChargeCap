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
    private var onboardingWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let args = CommandLine.arguments
        func value(after flag: String) -> String? {
            args.firstIndex(of: flag).flatMap { args.dropFirst($0 + 1).first }
        }

        if args.contains("--selftest") {
            let outDir = URL(fileURLWithPath: value(after: "--selftest") ?? "build/selftest")
            Task { @MainActor in
                let shots = value(after: "--screenshots").map { URL(fileURLWithPath: $0) }
                let ok = await SelfTest.run(outputDirectory: outDir, screenshotsDirectory: shots)
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

        NotificationCenter.default.addObserver(forName: .chargeCapShowOnboarding, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.showOnboardingWindow() }
        }
        // chargecap://open-settings?section=<name> (matches SettingsSection by raw value or case name, case-insensitive)
        NotificationCenter.default.addObserver(forName: .chargeCapOpenSettings, object: nil, queue: .main) { [weak self] note in
            let raw = (note.userInfo?["section"] as? String)?.lowercased().replacingOccurrences(of: "-", with: "")
            MainActor.assumeIsolated {
                let section = raw.flatMap { key in
                    SettingsSection.allCases.first {
                        $0.rawValue.lowercased().replacingOccurrences(of: " ", with: "") == key
                            || String(describing: $0).lowercased() == key
                    }
                }
                self?.openSettingsWindow(section: section)
            }
        }

        if !Prefs.shared.hasCompletedOnboarding && !Prefs.devMode {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.showOnboardingWindow()
            }
        }

        if args.contains("--open-popover") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                self.showPopover()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Persists transient state, flushes HistoryStore synchronously and restores the SMC.
        ChargeController.shared.handleAppTermination()
        SleepControl.shared.stop()
        EnergyMonitor.shared.stopSampling()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            URLCommands.handle(url)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Status item

    private func setupPopoverAndStatusItem() {
        let rootView = PopoverView { [weak self] in
            self?.openSettingsWindow(section: .general)
        }

        let hosting = NSHostingController(rootView: rootView)
        hosting.preferredContentSize = PopoverView.preferredSize
        hosting.view.frame = NSRect(origin: .zero, size: PopoverView.preferredSize)

        let pop = NSPopover()
        pop.contentSize = PopoverView.preferredSize
        pop.behavior = .transient
        pop.animates = true
        pop.contentViewController = hosting
        self.popover = pop

        statusBarItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusBarItem.button {
            button.imagePosition = .imageLeading
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        updateStatusBarButton()

        // Reactively update menu bar icon & readout whenever telemetry, prefs or helper state change.
        ChargeController.shared.objectWillChange
            .merge(with: Prefs.shared.objectWillChange, HelperClient.shared.objectWillChange)
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
        let snapshot = controller.snapshot
        let readout = MenuBarIconRenderer.readoutText(snapshot: snapshot, prefs: prefs)

        if prefs.menuBarIconStyle == .textOnly {
            button.image = nil
            button.title = readout.isEmpty ? "\(snapshot.osPercentage)%" : readout
        } else {
            button.image = MenuBarIconRenderer.renderStatusBarImage(snapshot: snapshot, mode: controller.operatingMode, prefs: prefs)
            button.title = readout
        }
        button.toolTip = "\(snapshot.osPercentage)% · \(controller.operatingMode.badgeText)"
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        if let event = NSApp.currentEvent, event.type == .rightMouseUp {
            switch Prefs.shared.menuBarRightClickAction {
            case .quickMenu: showQuickContextMenu()
            case .openSettings: openSettingsWindow(section: .general)
            case .toggleTopUp: ChargeController.shared.toggleTopUp()
            }
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
        popover.contentSize = PopoverView.preferredSize
        popover.contentViewController?.preferredContentSize = PopoverView.preferredSize
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

        if let popWin = popover.contentViewController?.view.window {
            let screen = popWin.screen ?? NSScreen.main ?? NSScreen.screens.first
            if let visible = screen?.visibleFrame, popWin.frame.maxY > visible.maxY {
                var adjusted = popWin.frame
                adjusted.origin.y = visible.maxY - adjusted.height - 2
                popWin.setFrame(adjusted, display: true)
            }
            popWin.makeKey()
        }
    }

    // MARK: - Quick menu

    private func menuItem(_ title: String, _ action: Selector, key: String = "", state: Bool = false, tag: Int = 0, represented: Any? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.state = state ? .on : .off
        item.tag = tag
        item.representedObject = represented
        return item
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
            menu.addItem(menuItem("Set Charge Limit to \(preset)%", #selector(selectPreset(_:)),
                                  state: prefs.chargeLimit == preset && !controller.isTopUpActive, tag: preset))
        }
        menu.addItem(.separator())

        menu.addItem(menuItem("Top Up to 100%", #selector(toggleTopUpAction), key: "t", state: controller.isTopUpActive))
        menu.addItem(menuItem(controller.isManualDischargeActive ? "Pause Discharge" : "Discharge to \(prefs.chargeLimit)%",
                              #selector(toggleDischargeAction), key: "d", state: controller.isManualDischargeActive))
        menu.addItem(menuItem("Sailing Mode (-\(prefs.sailingDelta)%)", #selector(toggleSailingAction), key: "s", state: prefs.sailingModeEnabled))
        menu.addItem(menuItem(controller.isCalibrating ? "Stop Calibration Mode" : "Start Calibration Mode",
                              #selector(toggleCalibrationAction), state: controller.isCalibrating))
        menu.addItem(.separator())

        // Sleep Control submenu
        let sleepMenu = NSMenu()
        let sleep = SleepControl.shared
        for (idx, duration) in SleepControlDuration.allCases.enumerated() {
            sleepMenu.addItem(menuItem("Keep Awake · \(duration.title)", #selector(startSleepControl(_:)), tag: idx))
        }
        if sleep.isActive {
            sleepMenu.addItem(.separator())
            sleepMenu.addItem(menuItem("Allow Sleep Again", #selector(stopSleepControl)))
        }
        let sleepParent = NSMenuItem(title: "Sleep Control", action: nil, keyEquivalent: "")
        sleepParent.state = sleep.isActive ? .on : .off
        sleepParent.submenu = sleepMenu
        menu.addItem(sleepParent)

        // Low Power Mode submenu
        let lpmMenu = NSMenu()
        for policy in LowPowerModePolicy.allCases {
            lpmMenu.addItem(menuItem(policy.title, #selector(selectLowPowerPolicy(_:)),
                                     state: prefs.lowPowerModePolicy == policy, represented: policy.rawValue))
        }
        let lpmParent = NSMenuItem(title: "Low Power Mode", action: nil, keyEquivalent: "")
        lpmParent.submenu = lpmMenu
        menu.addItem(lpmParent)

        menu.addItem(.separator())
        menu.addItem(menuItem("Settings…", #selector(openSettingsAction), key: ","))
        menu.addItem(menuItem("Quit ChargeCap", #selector(quitApp), key: "q"))

        statusBarItem.menu = menu
        statusBarItem.button?.performClick(nil)
        statusBarItem.menu = nil
    }

    @objc private func selectPreset(_ sender: NSMenuItem) {
        ChargeController.shared.isTopUpActive = false
        ChargeController.shared.setChargeLimit(sender.tag)
    }

    @objc private func toggleTopUpAction() { ChargeController.shared.toggleTopUp() }
    @objc private func toggleDischargeAction() { ChargeController.shared.toggleManualDischarge() }
    @objc private func toggleSailingAction() { Prefs.shared.sailingModeEnabled.toggle() }

    @objc private func toggleCalibrationAction() {
        if ChargeController.shared.isCalibrating {
            ChargeController.shared.stopCalibration()
        } else {
            ChargeController.shared.startCalibration()
        }
    }

    @objc private func startSleepControl(_ sender: NSMenuItem) {
        let all = SleepControlDuration.allCases
        guard sender.tag >= 0, sender.tag < all.count else { return }
        SleepControl.shared.start(all[sender.tag])
    }

    @objc private func stopSleepControl() { SleepControl.shared.stop() }

    @objc private func selectLowPowerPolicy(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let policy = LowPowerModePolicy(rawValue: raw) else { return }
        Prefs.shared.lowPowerModePolicy = policy
        ChargeController.shared.evaluateAndApply()
    }

    // MARK: - Windows

    @objc private func openSettingsAction() { openSettingsWindow(section: nil) }

    private func openSettingsWindow(section: SettingsSection? = nil) {
        popover?.performClose(nil)
        if let section { SettingsRouter.shared.selected = section }
        if settingsWindow == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 820, height: 600),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            win.title = "ChargeCap Settings"
            win.toolbarStyle = .unified
            win.contentViewController = NSHostingController(rootView: SettingsView())
            win.minSize = NSSize(width: 720, height: 520)
            win.isReleasedWhenClosed = false
            if !win.setFrameUsingName("ChargeCapSettings") { win.center() }
            win.setFrameAutosaveName("ChargeCapSettings")
            self.settingsWindow = win
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func showOnboardingWindow() {
        if onboardingWindow == nil {
            let win = NSWindow(
                contentRect: NSRect(origin: .zero, size: NSSize(width: OnboardingView.preferredSize.width, height: OnboardingView.preferredSize.height)),
                styleMask: [.titled, .closable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            win.title = "Welcome to ChargeCap"
            win.titlebarAppearsTransparent = true
            win.titleVisibility = .hidden
            win.isReleasedWhenClosed = false
            win.contentViewController = NSHostingController(rootView: OnboardingView { [weak self] in
                self?.onboardingWindow?.close()
                self?.onboardingWindow = nil
            })
            win.center()
            self.onboardingWindow = win
        }
        NSApp.activate()
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
