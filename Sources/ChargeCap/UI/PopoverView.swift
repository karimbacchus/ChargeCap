//
// PopoverView.swift
// ChargeCap (forked from AlDente ContentView.swift)
//
// MIT License
//

import AppKit
import ChargeCapCore
import SwiftUI

public enum PopoverTab: String, CaseIterable, Identifiable {
    case control = "Control"
    case powerFlow = "Power Flow"
    case stats = "Stats"
    case schedule = "Schedule"

    public var id: String { rawValue }

    public var symbolName: String {
        switch self {
        case .control: return "slider.horizontal.below.square.and.square.filled"
        case .powerFlow: return "bolt.horizontal.circle.fill"
        case .stats: return "chart.xyaxis.line"
        case .schedule: return "calendar.badge.clock"
        }
    }
}

public struct PopoverView: View {
    @ObservedObject private var controller = ChargeController.shared
    @ObservedObject private var prefs = Prefs.shared
    @ObservedObject private var helper = HelperClient.shared
    @ObservedObject private var scheduler = ScheduleManager.shared

    @State private var selectedTab: PopoverTab
    @State private var showNewScheduleSheet = false

    public var onOpenSettings: () -> Void

    public init(initialTab: PopoverTab = .control, onOpenSettings: @escaping () -> Void = {}) {
        _selectedTab = State(initialValue: initialTab)
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        VStack(spacing: 12) {
            headerBar
            heroBatteryCard
            tabSelector

            Group {
                switch selectedTab {
                case .control:
                    controlTabContent
                case .powerFlow:
                    PowerFlowTabView(snapshot: controller.snapshot, history: controller.history)
                case .stats:
                    StatsTabView(snapshot: controller.snapshot, history: controller.history, prefs: prefs)
                case .schedule:
                    ScheduleTabView(scheduler: scheduler, showNewSheet: $showNewScheduleSheet)
                }
            }
            .frame(maxWidth: .infinity)

            footerStatusStrip
        }
        .padding(14)
        .frame(width: 430)
        .background(
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.08),
                    Color.clear,
                    Color.cyan.opacity(0.05)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    // MARK: - Top Header Bar

    private var headerBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                ZStack {
                    Circle()
                        .fill(statusAccentColor.opacity(0.22))
                        .frame(width: 28, height: 28)
                    Image(systemName: controller.operatingMode.symbolName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(statusAccentColor)
                }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text("ChargeCap")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                        Circle()
                            .fill(magSafeDotColor)
                            .frame(width: 7, height: 7)
                            .help("MagSafe LED (\(prefs.magSafeLEDMode.title))")
                    }
                    Text(controller.operatingMode.badgeText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            HStack(spacing: 6) {
                Button {
                    controller.refreshNow()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.glass)
                .help("Refresh Telemetry")

                Button {
                    onOpenSettings()
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.glass)
                .help("Settings (⌘,)")

                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.glass)
                .help("Quit ChargeCap")
            }
        }
    }

    // MARK: - Hero Liquid Glass Battery Gauge Card

    private var heroBatteryCard: some View {
        let snap = controller.snapshot
        let limit = prefs.chargeLimit
        let sailLow = prefs.sailingTarget

        return VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(snap.osPercentage)%")
                            .font(.system(size: 32, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text(String(format: "HW %.1f%%", snap.hardwarePercentage))
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .glassEffect(.regular, in: .capsule)
                    }
                    Text(powerSummarySubtitle(snap))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 3) {
                    HStack(spacing: 4) {
                        Text("LIMIT")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                        Text("\(limit)%")
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.accentColor)
                            .monospacedDigit()
                    }
                    HStack(spacing: 6) {
                        Label(prefs.formatTemperature(snap.batteryTemperatureC), systemImage: "thermometer.medium")
                        Text("·")
                        Text(String(format: "%.0f%% Health", snap.healthPercentage))
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(snap.batteryTemperatureC >= prefs.heatProtectionMaxCelsius ? .orange : .secondary)
                }
            }

            // Visual Battery Bar with Sailing Zone + Charge Limit Pin
            GeometryReader { geo in
                let width = geo.size.width
                let fillWidth = max(8, width * CGFloat(min(100, max(0, snap.osPercentage))) / 100.0)
                let limitX = width * CGFloat(limit) / 100.0
                let sailX = width * CGFloat(sailLow) / 100.0

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.09))

                    // Sailing band highlight
                    if prefs.sailingModeEnabled && sailLow < limit {
                        Rectangle()
                            .fill(Color.cyan.opacity(0.22))
                            .frame(width: max(2, limitX - sailX))
                            .offset(x: sailX)
                    }

                    // Current battery fill
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [statusAccentColor.opacity(0.85), statusAccentColor],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: fillWidth)

                    // Sailing lower marker
                    if prefs.sailingModeEnabled && sailLow < limit {
                        Rectangle()
                            .fill(Color.cyan.opacity(0.85))
                            .frame(width: 1.5, height: 16)
                            .offset(x: max(0, min(width - 2, sailX)))
                    }

                    // Target Charge Limit marker line
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.primary)
                        .frame(width: 3, height: 20)
                        .offset(x: max(0, min(width - 3, limitX - 1.5)))
                }
            }
            .frame(height: 16)

            // Slider + Stepper
            HStack(spacing: 10) {
                Slider(
                    value: Binding(
                        get: { Double(prefs.chargeLimit) },
                        set: { controller.setChargeLimit(Int($0.rounded())) }
                    ),
                    in: Double(prefs.minAllowedChargeLimit)...100,
                    step: 1
                )

                HStack(spacing: 3) {
                    Button {
                        controller.setChargeLimit(max(prefs.minAllowedChargeLimit, prefs.chargeLimit - 1))
                    } label: {
                        Image(systemName: "minus")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.glass)

                    Button {
                        controller.setChargeLimit(min(100, prefs.chargeLimit + 1))
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.glass)
                }
            }

            // Quick Preset Glass Pills
            HStack(spacing: 6) {
                ForEach(prefs.quickPresets, id: \.self) { preset in
                    let isSelected = (prefs.chargeLimit == preset && !controller.isTopUpActive)
                    Button {
                        controller.isTopUpActive = false
                        controller.setChargeLimit(preset)
                    } label: {
                        Text("\(preset)%")
                            .font(.system(size: 11, weight: isSelected ? .bold : .medium, design: .rounded))
                            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 3)
                    }
                    .buttonStyle(.glass)
                    .tint(isSelected ? .accentColor : nil)
                }
            }
        }
        .padding(12)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
    }

    // MARK: - Segmented Glass Tab Selector

    private var tabSelector: some View {
        HStack(spacing: 6) {
            ForEach(PopoverTab.allCases) { tab in
                let active = (selectedTab == tab)
                Button {
                    withAnimation(.snappy(duration: 0.2)) {
                        selectedTab = tab
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: tab.symbolName)
                            .font(.system(size: 11, weight: .semibold))
                        Text(tab.rawValue)
                            .font(.system(size: 11, weight: active ? .bold : .medium))
                    }
                    .foregroundStyle(active ? Color.accentColor : Color.primary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                }
                .buttonStyle(.glass)
                .tint(active ? .accentColor : nil)
            }
        }
    }

    // MARK: - Control Tab Content (AlDente Pro Modes)

    private var controlTabContent: some View {
        VStack(spacing: 10) {
            if let calPhase = controller.calibrationPhase {
                calibrationBanner(phase: calPhase)
            }

            // 2x3 Grid of AlDente Pro Feature Cards
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    // 1. Active / Auto Discharge
                    modeTile(
                        title: "Discharge",
                        subtitle: controller.isManualDischargeActive
                            ? "Discharging to \(prefs.chargeLimit)%"
                            : (prefs.autoDischargeEnabled ? "Auto-Discharge On" : "Run on battery plugged in"),
                        symbol: "arrow.down.circle.fill",
                        isActive: controller.isManualDischargeActive || prefs.autoDischargeEnabled,
                        tint: .orange
                    ) {
                        controller.toggleManualDischarge()
                    }

                    // 2. Top Up to 100%
                    modeTile(
                        title: "Top Up",
                        subtitle: controller.isTopUpActive
                            ? "Charging to 100% now"
                            : "One-click full charge",
                        symbol: "arrow.up.to.line.circle.fill",
                        isActive: controller.isTopUpActive,
                        tint: .green
                    ) {
                        controller.toggleTopUp()
                    }
                }

                HStack(spacing: 8) {
                    // 3. Sailing Mode
                    modeTile(
                        title: "Sailing Mode",
                        subtitle: prefs.sailingModeEnabled
                            ? "Sail \(prefs.sailingTarget)%–\(prefs.chargeLimit)% (-\(prefs.sailingDelta)%)"
                            : "Prevent micro-charges",
                        symbol: "sailboat.fill",
                        isActive: prefs.sailingModeEnabled,
                        tint: .cyan
                    ) {
                        prefs.sailingModeEnabled.toggle()
                    }

                    // 4. Heat Protection
                    modeTile(
                        title: "Heat Protection",
                        subtitle: prefs.heatProtectionEnabled
                            ? "Max \(prefs.formatTemperature(prefs.heatProtectionMaxCelsius)) · Live \(prefs.formatTemperature(controller.snapshot.batteryTemperatureC))"
                            : "Pause when battery hot",
                        symbol: "flame.fill",
                        isActive: prefs.heatProtectionEnabled,
                        tint: controller.isHeatPaused ? .red : .pink
                    ) {
                        prefs.heatProtectionEnabled.toggle()
                    }
                }

                HStack(spacing: 8) {
                    // 5. Calibration Mode
                    modeTile(
                        title: "Calibration Mode",
                        subtitle: controller.calibrationPhase?.shortTitle ?? "100% → 15% → 100% cycle",
                        symbol: "arrow.triangle.2.circlepath.circle.fill",
                        isActive: controller.isCalibrating,
                        tint: .purple
                    ) {
                        if controller.isCalibrating {
                            controller.stopCalibration()
                        } else {
                            controller.startCalibration()
                        }
                    }

                    // 6. MagSafe LED Control (cycles modes on click)
                    modeTile(
                        title: "MagSafe LED",
                        subtitle: prefs.magSafeLEDMode.title,
                        symbol: "cable.connector.horizontal",
                        isActive: prefs.magSafeLEDMode != .system,
                        tint: magSafeDotColor
                    ) {
                        let all = MagSafeLEDMode.allCases
                        if let idx = all.firstIndex(of: prefs.magSafeLEDMode) {
                            prefs.magSafeLEDMode = all[(idx + 1) % all.count]
                            controller.evaluateAndApply()
                        }
                    }
                }
            }

            // Fine-tuning row for Sailing Delta, Heat Protection Threshold & Auto-Discharge
            VStack(spacing: 8) {
                glassSwitchRow(
                    title: "Automatic Discharge above Limit",
                    symbol: "bolt.badge.automatic.fill",
                    isOn: $prefs.autoDischargeEnabled
                )

                glassSwitchRow(
                    title: "Stop Charging When Sleeping",
                    symbol: "moon.stars.fill",
                    isOn: $prefs.stopChargingWhenSleeping
                )

                glassSwitchRow(
                    title: "Use Hardware BMS Percentage (\(String(format: "%.1f%%", controller.snapshot.hardwarePercentage)))",
                    symbol: "cpu.fill",
                    isOn: $prefs.useHardwarePercentage
                )
            }
            .padding(10)
            .glassEffect(.regular, in: .rect(cornerRadius: 13))
        }
    }

    private func glassSwitchRow(title: String, symbol: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
            Spacer()
            ZStack(alignment: isOn.wrappedValue ? .trailing : .leading) {
                Capsule()
                    .fill(isOn.wrappedValue ? Color.accentColor : Color.primary.opacity(0.18))
                    .frame(width: 32, height: 18)
                Circle()
                    .fill(Color.white)
                    .frame(width: 14, height: 14)
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

    private func calibrationBanner(phase: CalibrationPhase) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .foregroundStyle(.purple)
                Text(phase.title)
                    .font(.system(size: 12, weight: .bold))
                Spacer()
                Button("Next Step") {
                    controller.advanceCalibrationStep()
                }
                .buttonStyle(.glass)
                .controlSize(.small)

                Button("Cancel") {
                    controller.stopCalibration()
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }

            ProgressView(value: Double(phase.rawValue), total: 5.0)
                .tint(.purple)
        }
        .padding(10)
        .glassEffect(.regular, in: .rect(cornerRadius: 13))
    }

    private func modeTile(
        title: String,
        subtitle: String,
        symbol: String,
        isActive: Bool,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 9) {
            ZStack {
                Circle()
                    .fill(isActive ? tint : Color.primary.opacity(0.10))
                    .frame(width: 30, height: 30)
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isActive ? Color.white : tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 13))
        .contentShape(.rect(cornerRadius: 13))
        .onTapGesture(perform: action)
    }

    // MARK: - Footer Helper & SMC Status Strip

    private var footerStatusStrip: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(helper.isHelperConnected ? Color.green : Color.orange)
                .frame(width: 7, height: 7)

            Text(helper.isHelperConnected ? controller.lastActionSummary : helper.helperStatusMessage)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            if !helper.isHelperConnected {
                Button("Install Helper") {
                    helper.installHelper()
                }
                .font(.system(size: 10.5, weight: .semibold))
                .buttonStyle(.glassProminent)
                .controlSize(.small)
            } else {
                Text(helper.detectedKeyFamily == .appleSiliconModern ? "SMC: CHIB/CHIE" : "SMC Ready")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
    }

    // MARK: - Helpers

    private var statusAccentColor: Color {
        switch controller.operatingMode {
        case .chargingToLimit, .topUp:
            return .green
        case .holdingAtLimit:
            return .blue
        case .sailing:
            return .cyan
        case .discharging:
            return .orange
        case .calibrating:
            return .purple
        case .heatProtectionPaused:
            return .red
        case .onBattery, .sleepingPaused:
            return .secondary
        }
    }

    private var magSafeDotColor: Color {
        switch prefs.magSafeLEDMode {
        case .green: return .green
        case .orange: return .orange
        case .off: return .gray
        case .system: return .blue
        case .auto:
            switch controller.operatingMode {
            case .chargingToLimit, .topUp, .heatProtectionPaused:
                return .orange
            default:
                return .green
            }
        }
    }

    private func powerSummarySubtitle(_ snap: BatterySnapshot) -> String {
        if snap.isPluggedIn {
            let batFlow = abs(snap.batteryPowerWatts) < 0.2
                ? "Battery Bypassed"
                : (snap.batteryPowerWatts > 0
                    ? String(format: "+%.1fW to Battery", snap.batteryPowerWatts)
                    : String(format: "%.1fW from Battery", snap.batteryPowerWatts))
            return String(format: "%@ · %.1fW System · %@", snap.adapterName, snap.systemLoadWatts, batFlow)
        } else {
            return String(format: "On Battery · %.1fW System Draw", max(abs(snap.batteryPowerWatts), snap.systemLoadWatts))
        }
    }
}

// MARK: - Power Flow Tab View

private struct PowerFlowTabView: View {
    let snapshot: BatterySnapshot
    let history: [TelemetryHistoryPoint]

    var body: some View {
        VStack(spacing: 10) {
            // Visual Power Routing Graph
            VStack(spacing: 12) {
                HStack {
                    Text("Live Energy Routing")
                        .font(.system(size: 12, weight: .bold))
                    Spacer()
                    Text(snapshot.isPluggedIn ? snapshot.adapterName : "Internal Battery Pack")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    powerNode(
                        title: "Adapter In",
                        watts: snapshot.adapterInputWatts,
                        detail: snapshot.isPluggedIn
                            ? String(format: "%.1fV · %.1fA (%dW)", snapshot.adapterNegotiatedVolts, snapshot.adapterNegotiatedAmps, snapshot.adapterRatedWatts)
                            : "Unplugged",
                        symbol: "powerplug.fill",
                        tint: snapshot.adapterInputWatts > 0 ? .green : .secondary
                    )

                    Image(systemName: "arrow.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)

                    powerNode(
                        title: "Mac System",
                        watts: snapshot.systemLoadWatts,
                        detail: String(format: "Loss %.1fW", snapshot.adapterEfficiencyLossWatts),
                        symbol: "laptopcomputer",
                        tint: .blue
                    )

                    Image(systemName: snapshot.batteryPowerWatts >= 0 ? "arrow.left.and.right" : "arrow.left")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)

                    powerNode(
                        title: "Battery",
                        watts: snapshot.batteryPowerWatts,
                        detail: String(format: "%.2fV · %.2fA", snapshot.voltageVolts, snapshot.amperageAmps),
                        symbol: "battery.100percent.bolt",
                        tint: snapshot.batteryPowerWatts > 0.3 ? .green : (snapshot.batteryPowerWatts < -0.3 ? .orange : .cyan),
                        signed: true
                    )
                }

                HStack(spacing: 14) {
                    Label(String(format: "USB-C Ports Out: %.2fW", snapshot.usbExternalOutWatts), systemImage: "cable.connector")
                    Spacer()
                    Label(String(format: "Pack Voltage: %.2fV", snapshot.voltageVolts), systemImage: "bolt.circle")
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            }
            .padding(12)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))

            // Rolling Wattage Chart
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Power History (Watts)")
                        .font(.system(size: 11, weight: .bold))
                    Spacer()
                    HStack(spacing: 10) {
                        legendDot(title: "Adapter", color: .green)
                        legendDot(title: "System", color: .blue)
                        legendDot(title: "Battery", color: .orange)
                    }
                }

                TelemetrySparkline(
                    points: history,
                    series: [
                        ({ $0.adapterWatts }, .green),
                        ({ $0.systemWatts }, .blue),
                        ({ abs($0.batteryWatts) }, .orange)
                    ]
                )
                .frame(height: 82)
            }
            .padding(12)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
        }
    }

    private func powerNode(
        title: String,
        watts: Double,
        detail: String,
        symbol: String,
        tint: Color,
        signed: Bool = false
    ) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(signed ? String(format: "%+.1fW", watts) : String(format: "%.1fW", watts))
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(detail)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .background(tint.opacity(0.10), in: .rect(cornerRadius: 11))
    }

    private func legendDot(title: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Stats Tab View

private struct StatsTabView: View {
    let snapshot: BatterySnapshot
    let history: [TelemetryHistoryPoint]
    @ObservedObject var prefs: Prefs

    var body: some View {
        VStack(spacing: 9) {
            // Capacity & Health Grid
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 7) {
                statPill(label: "macOS / HW %", value: String(format: "%d%% / %.1f%%", snapshot.osPercentage, snapshot.hardwarePercentage))
                statPill(label: "Battery Health", value: String(format: "%.1f%% (%d cyc)", snapshot.healthPercentage, snapshot.cycleCount))
                statPill(label: "Capacity (mAh)", value: "\(snapshot.currentCapacityMah) / \(snapshot.fullChargeCapacityMah)")
                statPill(label: "Design mAh", value: "\(snapshot.designCapacityMah) mAh")
                statPill(label: "Pack Voltage", value: String(format: "%.3f V", snapshot.voltageVolts))
                statPill(label: "Battery Temp", value: prefs.formatTemperature(snapshot.batteryTemperatureC))
            }

            // Individual Cell Balance Card
            if !snapshot.cellVoltagesMillivolts.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Individual Cell Voltages (SMC BC1V–BC3V)")
                            .font(.system(size: 11, weight: .bold))
                        Spacer()
                        Text("Delta: \(snapshot.cellDeltaMillivolts) mV")
                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(snapshot.cellDeltaMillivolts < 25 ? .green : .orange)
                    }
                    HStack(spacing: 8) {
                        ForEach(Array(snapshot.cellVoltagesMillivolts.enumerated()), id: \.offset) { idx, mv in
                            HStack {
                                Text("Cell \(idx + 1)")
                                    .font(.system(size: 10.5, weight: .medium))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text("\(mv) mV")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color.primary.opacity(0.07), in: .rect(cornerRadius: 8))
                        }
                    }
                }
                .padding(10)
                .glassEffect(.regular, in: .rect(cornerRadius: 13))
            }

            // Thermal Sensors & Lifetime Extremes
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Thermal Telemetry (SMC TB0T–TB2T)")
                        .font(.system(size: 11, weight: .bold))
                    Spacer()
                    if let minT = snapshot.minLifetimeTemperatureC, let maxT = snapshot.maxLifetimeTemperatureC {
                        Text("Lifetime: \(prefs.formatTemperature(minT)) – \(prefs.formatTemperature(maxT))")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }

                TelemetrySparkline(
                    points: history,
                    series: [
                        ({ $0.temperatureC }, .pink),
                        ({ $0.hwPercent }, .cyan)
                    ]
                )
                .frame(height: 56)
            }
            .padding(10)
            .glassEffect(.regular, in: .rect(cornerRadius: 13))
        }
    }

    private func statPill(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 11.5, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 11))
    }
}

// MARK: - Schedule Tab View

private struct ScheduleTabView: View {
    @ObservedObject var scheduler: ScheduleManager
    @Binding var showNewSheet: Bool

    @State private var newName: String = "Evening Limit"
    @State private var newAction: ScheduleActionType = .setChargeLimit
    @State private var newFrequency: ScheduleFrequency = .daily
    @State private var newHour: Int = 20
    @State private var newMinute: Int = 0
    @State private var newTargetLimit: Int = 70

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Scheduled Automations")
                    .font(.system(size: 12, weight: .bold))
                Spacer()
                Button {
                    withAnimation(.snappy) { showNewSheet.toggle() }
                } label: {
                    Label(showNewSheet ? "Close" : "Add Schedule", systemImage: showNewSheet ? "xmark" : "plus")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }

            if showNewSheet {
                VStack(spacing: 7) {
                    HStack(spacing: 6) {
                        TextField("Schedule Name", text: $newName)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11))

                        Picker("", selection: $newAction) {
                            ForEach(ScheduleActionType.allCases) { act in
                                Text(act.title).tag(act)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 155)
                    }

                    HStack(spacing: 6) {
                        Picker("", selection: $newFrequency) {
                            ForEach(ScheduleFrequency.allCases) { freq in
                                Text(freq.title).tag(freq)
                            }
                        }
                        .labelsHidden()

                        Stepper(
                            String(format: "%02d:%02d", newHour, newMinute),
                            value: $newHour,
                            in: 0...23
                        )
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))

                        if newAction == .setChargeLimit || newAction == .startDischarge {
                            Stepper("\(newTargetLimit)%", value: $newTargetLimit, in: 20...100, step: 5)
                                .font(.system(size: 11, weight: .semibold))
                        }

                        Spacer()

                        Button("Save") {
                            let task = ScheduledTask(
                                name: newName.isEmpty ? "Scheduled Task" : newName,
                                isEnabled: true,
                                frequency: newFrequency,
                                hour: newHour,
                                minute: newMinute,
                                action: newAction,
                                targetLimit: newTargetLimit
                            )
                            scheduler.addTask(task)
                            showNewSheet = false
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.small)
                    }
                }
                .padding(10)
                .glassEffect(.regular, in: .rect(cornerRadius: 12))
            }

            ForEach(scheduler.tasks) { task in
                HStack(spacing: 8) {
                    Image(systemName: task.action.symbolName)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(task.isEnabled ? Color.accentColor : .secondary)
                        .frame(width: 22)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(task.name)
                            .font(.system(size: 11.5, weight: .semibold))
                        Text(task.summaryText)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Run") {
                        scheduler.executeNow(task)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.mini)

                    ZStack(alignment: task.isEnabled ? .trailing : .leading) {
                        Capsule()
                            .fill(task.isEnabled ? Color.accentColor : Color.primary.opacity(0.18))
                            .frame(width: 30, height: 16)
                        Circle()
                            .fill(Color.white)
                            .frame(width: 12, height: 12)
                            .padding(.horizontal, 2)
                    }
                    .onTapGesture {
                        scheduler.toggleTask(id: task.id)
                    }

                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .onTapGesture {
                            scheduler.removeTask(id: task.id)
                        }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .glassEffect(.regular, in: .rect(cornerRadius: 11))
            }
        }
    }
}

// MARK: - Telemetry Sparkline Canvas

private struct TelemetrySparkline: View {
    let points: [TelemetryHistoryPoint]
    let series: [((TelemetryHistoryPoint) -> Double, Color)]

    var body: some View {
        Canvas { ctx, size in
            let gridColor = Color.primary.opacity(0.08)
            for row in 1...3 {
                let y = size.height * CGFloat(row) / 4.0
                var gridPath = Path()
                gridPath.move(to: CGPoint(x: 0, y: y))
                gridPath.addLine(to: CGPoint(x: size.width, y: y))
                ctx.stroke(gridPath, with: .color(gridColor), lineWidth: 0.7)
            }

            guard !points.isEmpty else { return }
            let allVals = series.flatMap { fn, _ in points.map(fn) }
            let maxVal = max(10.0, (allVals.max() ?? 100.0) * 1.1)
            let minVal = min(0.0, allVals.min() ?? 0.0)
            let span = max(1.0, maxVal - minVal)

            for (extractor, color) in series {
                var path = Path()
                let count = max(2, points.count)
                for (index, pt) in points.enumerated() {
                    let x = count == 1 ? size.width : (size.width * CGFloat(index) / CGFloat(count - 1))
                    let val = extractor(pt)
                    let norm = (val - minVal) / span
                    let y = size.height - (CGFloat(norm) * (size.height - 6)) - 3
                    if index == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
                if points.count == 1, let first = points.first {
                    let val = extractor(first)
                    let norm = (val - minVal) / span
                    let y = size.height - (CGFloat(norm) * (size.height - 6)) - 3
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                }
                ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
            }
        }
    }
}
