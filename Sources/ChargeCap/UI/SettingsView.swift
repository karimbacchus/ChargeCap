//
// SettingsView.swift
// ChargeCap
//
// MIT License
//

import AppKit
import ChargeCapCore
import SwiftUI

public enum SettingsSection: String, CaseIterable, Identifiable {
    case charging = "Charging"
    case protection = "Protection"
    case menuBar = "Menu Bar"
    case automations = "Automations"
    case helper = "Helper"

    public var id: String { rawValue }

    public var symbolName: String {
        switch self {
        case .charging: return "bolt.batteryblock.fill"
        case .protection: return "flame.fill"
        case .menuBar: return "menubar.rectangle"
        case .automations: return "calendar.badge.clock"
        case .helper: return "wrench.and.screwdriver.fill"
        }
    }
}

public struct SettingsView: View {
    @ObservedObject private var prefs = Prefs.shared
    @ObservedObject private var controller = ChargeController.shared
    @ObservedObject private var helper = HelperClient.shared

    @State private var selectedSection: SettingsSection = .charging

    public init() {}

    public var body: some View {
        VStack(spacing: 14) {
            // Top Liquid Glass Tab Selector
            HStack(spacing: 6) {
                ForEach(SettingsSection.allCases) { section in
                    let active = (selectedSection == section)
                    Button {
                        withAnimation(.snappy(duration: 0.18)) {
                            selectedSection = section
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: section.symbolName)
                                .font(.system(size: 11, weight: .semibold))
                            Text(section.rawValue)
                                .font(.system(size: 11.5, weight: active ? .bold : .medium))
                        }
                        .foregroundStyle(active ? Color.accentColor : Color.primary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.glass)
                    .tint(active ? .accentColor : nil)
                }
            }

            Group {
                switch selectedSection {
                case .charging:
                    chargingSettingsTab
                case .protection:
                    protectionSleepTab
                case .menuBar:
                    menuBarAppearanceTab
                case .automations:
                    automationsTab
                case .helper:
                    helperDiagnosticsTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(18)
        .frame(width: 580, height: 470)
    }

    // MARK: - Tab 1: Charging & Sailing

    private var chargingSettingsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingsCard(title: "Charge Limiter & Battery Percentage", symbol: "battery.75") {
                HStack {
                    Text("Maximum Charge Limit")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Slider(
                        value: Binding(
                            get: { Double(prefs.chargeLimit) },
                            set: { prefs.chargeLimit = Int($0.rounded()) }
                        ),
                        in: Double(prefs.minAllowedChargeLimit)...100,
                        step: 1
                    )
                    .frame(width: 180)
                    Text("\(prefs.chargeLimit)%")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }

                glassToggleRow("Allow Charge Limits Below 20% (10%–100%)", isOn: $prefs.allowLowLimits)
                glassToggleRow("Use Hardware BMS Battery Percentage (Raw mAh Ratio)", isOn: $prefs.useHardwarePercentage)

                Text("macOS displays \(controller.snapshot.osPercentage)% while the battery controller reports \(String(format: "%.1f%%", controller.snapshot.hardwarePercentage)) (\(controller.snapshot.currentCapacityMah) / \(controller.snapshot.fullChargeCapacityMah) mAh).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            settingsCard(title: "Sailing Mode", symbol: "sailboat.fill") {
                glassToggleRow("Enable Sailing Mode", isOn: $prefs.sailingModeEnabled)

                HStack {
                    Text("Sailing Difference")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Slider(
                        value: Binding(
                            get: { Double(prefs.sailingDelta) },
                            set: { prefs.sailingDelta = Int($0.rounded()) }
                        ),
                        in: 1...30,
                        step: 1
                    )
                    .frame(width: 180)
                    Text("-\(prefs.sailingDelta)% (Sails to \(prefs.sailingTarget)%)")
                        .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .frame(width: 135, alignment: .trailing)
                }
                .disabled(!prefs.sailingModeEnabled)
            }

            settingsCard(title: "Automatic Discharge & Top Up", symbol: "arrow.up.arrow.down.circle.fill") {
                glassToggleRow("Automatic Discharge when Plugged In Above Limit", isOn: $prefs.autoDischargeEnabled)
                glassToggleRow("Allow Discharge in Clamshell Mode (Prevent Sleep)", isOn: $prefs.dischargeInClamshell)
                glassToggleRow("Top Up: Automatically Return to Limit When Unplugged", isOn: $prefs.topUpAutoRevertOnUnplug)
                glassToggleRow("Top Up: Automatically Return to Limit at 100%", isOn: $prefs.topUpAutoRevertAt100)
            }
        }
    }

    // MARK: - Tab 2: Heat Protection, Sleep & MagSafe

    private var protectionSleepTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingsCard(title: "Heat Protection", symbol: "flame.fill") {
                glassToggleRow("Pause Charging When Battery Temperature Exceeds Limit", isOn: $prefs.heatProtectionEnabled)

                HStack {
                    Text("Max Charging Temperature")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Slider(value: $prefs.heatProtectionMaxCelsius, in: 25...45, step: 0.5)
                        .frame(width: 190)
                    Text(prefs.formatTemperature(prefs.heatProtectionMaxCelsius))
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .frame(width: 70, alignment: .trailing)
                }
                .disabled(!prefs.heatProtectionEnabled)

                Text("Current battery temperature: \(prefs.formatTemperature(controller.snapshot.batteryTemperatureC)). Resumes after a 2.0°C cooldown hysteresis.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            settingsCard(title: "Sleep & Shutdown Behavior", symbol: "moon.zzz.fill") {
                glassToggleRow("Stop Charging Before macOS Enters Sleep", isOn: $prefs.stopChargingWhenSleeping)
                glassToggleRow("Disable System Sleep Until Charge Limit is Reached", isOn: $prefs.disableSleepUntilChargeLimit)
                glassToggleRow("Keep Charge Inhibit Active When Quitting ChargeCap", isOn: $prefs.stopChargingWhenPoweredOff)
            }

            settingsCard(title: "MagSafe 3 LED Control (SMC ACLC)", symbol: "cable.connector.horizontal") {
                HStack(spacing: 6) {
                    ForEach(MagSafeLEDMode.allCases) { mode in
                        let selected = (prefs.magSafeLEDMode == mode)
                        Button {
                            prefs.magSafeLEDMode = mode
                            controller.evaluateAndApply()
                        } label: {
                            Text(mode.title)
                                .font(.system(size: 10.5, weight: selected ? .bold : .medium))
                                .padding(.vertical, 4)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                        .tint(selected ? .accentColor : nil)
                    }
                }
            }
        }
    }

    // MARK: - Tab 3: Menu Bar & Appearance

    private var menuBarAppearanceTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingsCard(title: "Menu Bar Icon Style", symbol: "menubar.rectangle") {
                HStack(spacing: 6) {
                    ForEach(MenuBarIconStyle.allCases) { style in
                        let selected = (prefs.menuBarIconStyle == style)
                        Button {
                            prefs.menuBarIconStyle = style
                        } label: {
                            Text(style.title)
                                .font(.system(size: 11, weight: selected ? .bold : .medium))
                                .padding(.vertical, 5)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                        .tint(selected ? .accentColor : nil)
                    }
                }
            }

            settingsCard(title: "Menu Bar Live Readout", symbol: "textformat.123") {
                HStack(spacing: 6) {
                    ForEach(MenuBarReadoutMode.allCases) { mode in
                        let selected = (prefs.menuBarReadoutMode == mode)
                        Button {
                            prefs.menuBarReadoutMode = mode
                        } label: {
                            Text(mode.title)
                                .font(.system(size: 10.5, weight: selected ? .bold : .medium))
                                .padding(.vertical, 5)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glass)
                        .tint(selected ? .accentColor : nil)
                    }
                }
            }

            settingsCard(title: "Startup, Units & Notifications", symbol: "bell.badge.fill") {
                glassToggleRow("Launch ChargeCap at Login", isOn: $prefs.launchAtLogin)
                glassToggleRow("Display Temperatures in Fahrenheit (°F)", isOn: $prefs.temperatureUnitFahrenheit)
                glassToggleRow("Show macOS Notifications on Limit Reached & Thermal Pause", isOn: $prefs.notificationsEnabled)
            }
        }
    }

    // MARK: - Tab 4: Automations, Shortcuts & URL Scheme

    private var automationsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingsCard(title: "Apple Shortcuts Integration (AppIntents)", symbol: "square.stack.3d.up.fill") {
                Text("ChargeCap registers native macOS AppIntents with the Shortcuts app and Spotlight:")
                    .font(.subheadline)
                VStack(alignment: .leading, spacing: 4) {
                    Text("• Set Battery Charge Limit")
                    Text("• Top Up Battery to 100%")
                    Text("• Discharge Battery to Limit")
                    Text("• Control Battery Calibration Mode")
                    Text("• Configure Sailing Mode")
                    Text("• Get Battery & Power Flow Status")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            settingsCard(title: "URL Scheme Automation (chargecap://)", symbol: "terminal.fill") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("chargecap://set-limit?percent=80")
                    Text("chargecap://top-up?enable=true")
                    Text("chargecap://discharge?enable=true")
                    Text("chargecap://calibrate?action=start")
                    Text("chargecap://sailing?enable=true&delta=5")
                    Text("chargecap://heat-protection?enable=true&maxTemp=35")
                    Text("chargecap://magsafe?mode=auto|green|orange|off|system")
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Tab 5: Privileged Helper & Diagnostics

    private var helperDiagnosticsTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            settingsCard(title: "Privileged SMC Helper Daemon", symbol: "lock.shield.fill") {
                HStack {
                    Circle()
                        .fill(helper.isHelperConnected ? Color.green : Color.orange)
                        .frame(width: 9, height: 9)
                    Text(helper.helperStatusMessage)
                        .font(.subheadline.weight(.medium))
                    Spacer()
                }

                HStack(spacing: 10) {
                    Button("Install / Reinstall Helper") {
                        helper.installHelperWithAdminPrompt()
                    }
                    .buttonStyle(.glassProminent)

                    Button("Check Status") {
                        helper.checkHelperStatus()
                    }
                    .buttonStyle(.glass)

                    Button("Reset SMC Keys & Uninstall Helper") {
                        helper.resetAllOnExit()
                        helper.uninstallHelper()
                    }
                    .buttonStyle(.glass)
                }

                glassToggleRow("Use Classic Intel SMC Key (BCLM)", isOn: $prefs.useClassicIntelKey)
            }

            settingsCard(title: "About ChargeCap", symbol: "info.circle.fill") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ChargeCap for macOS 27")
                        .font(.headline)
                    Text("Modern Liquid Glass fork of AlDente's open-source foundation with full pro-grade battery care, Power Flow telemetry, Sailing Mode, Heat Protection, Top Up, Calibration Mode, MagSafe LED sync, and Shortcuts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("MIT License · Detected Hardware: \(helper.detectedKeyFamily.rawValue)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func glassToggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
            Spacer()
            ZStack(alignment: isOn.wrappedValue ? .trailing : .leading) {
                Capsule()
                    .fill(isOn.wrappedValue ? Color.accentColor : Color.primary.opacity(0.18))
                    .frame(width: 34, height: 19)
                Circle()
                    .fill(Color.white)
                    .frame(width: 15, height: 15)
                    .padding(.horizontal, 2)
            }
        }
        .contentShape(.rect)
        .onTapGesture {
            withAnimation(.snappy(duration: 0.18)) {
                isOn.wrappedValue.toggle()
            }
        }
    }

    private func settingsCard<Content: View>(
        title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: symbol)
                .font(.system(size: 13, weight: .bold))
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
    }
}
