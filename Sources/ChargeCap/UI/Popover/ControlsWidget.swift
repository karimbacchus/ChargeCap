//
// ControlsWidget.swift
// Top Up, Discharge, Sailing, Calibration and Heat Protection.
//

import ChargeCapCore
import SwiftUI

struct ControlsWidget: View {
    @ObservedObject var controller: ChargeController
    @ObservedObject var prefs: Prefs

    var body: some View {
        WidgetCard(title: "Controls", symbol: "slider.horizontal.3") {
            VStack(spacing: 8) {
                tileGrid

                if let phase = controller.calibrationPhase {
                    CalibrationRow(controller: controller, phase: phase)
                }

                heatRow

                HStack {
                    Label("Discharge Automatically Above Limit", systemImage: "arrow.down.circle")
                        .font(.footnote)
                    Spacer()
                    Toggle("Automatic discharge", isOn: $prefs.autoDischargeEnabled)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }
                .padding(.top, 2)
            }
        }
    }

    // MARK: Tiles

    private struct TileModel: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let symbol: String
        let isActive: Bool
        let tint: Color
        let action: () -> Void
    }

    private var tiles: [TileModel] {
        var result: [TileModel] = [
            TileModel(
                id: "topup", title: "Top Up",
                subtitle: controller.isTopUpActive ? "Charging to 100%" : "Full charge once",
                symbol: "arrow.up.to.line.circle.fill",
                isActive: controller.isTopUpActive, tint: .green,
                action: { controller.toggleTopUp() })
        ]
        // As in AlDente: with automatic discharge on, the manual button is redundant.
        if !prefs.autoDischargeEnabled {
            result.append(TileModel(
                id: "discharge", title: "Discharge",
                subtitle: controller.isManualDischargeActive ? "Down to \(prefs.chargeLimit)%" : "Run on battery",
                symbol: "arrow.down.circle.fill",
                isActive: controller.isManualDischargeActive, tint: .orange,
                action: { controller.toggleManualDischarge() }))
        }
        result.append(TileModel(
            id: "sailing", title: "Sailing",
            subtitle: prefs.sailingModeEnabled
                ? "\(prefs.sailingTarget)–\(prefs.chargeLimit)%" : "Avoid micro-charges",
            symbol: "sailboat.fill",
            isActive: prefs.sailingModeEnabled, tint: .cyan,
            action: { prefs.sailingModeEnabled.toggle() }))
        result.append(TileModel(
            id: "calibration", title: "Calibration",
            subtitle: controller.calibrationPhase?.shortTitle ?? "Recalibrate gauge",
            symbol: "arrow.triangle.2.circlepath.circle.fill",
            isActive: controller.isCalibrating, tint: .purple,
            action: {
                if controller.isCalibrating { controller.stopCalibration() } else { controller.startCalibration() }
            }))
        return result
    }

    private var tileGrid: some View {
        let all = tiles
        let rows = stride(from: 0, to: all.count, by: 2).map { Array(all[$0..<min($0 + 2, all.count)]) }
        return VStack(spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 8) {
                    ForEach(row) { t in
                        ModeTile(title: t.title, subtitle: t.subtitle, symbol: t.symbol,
                                 isActive: t.isActive, tint: t.tint, action: { withAnimation(.snappy) { t.action() } })
                    }
                }
            }
        }
    }

    // MARK: Heat protection

    private var heatRow: some View {
        let paused = controller.isHeatPaused
        let live = prefs.formatTemperature(controller.snapshot.batteryTemperatureC)
        let subtitle: String
        if !prefs.heatProtectionEnabled { subtitle = "Pause charging when hot" }
        else if paused { subtitle = "Paused at \(live)" }
        else { subtitle = "Max \(prefs.formatTemperature(prefs.heatProtectionMaxCelsius)) · now \(live)" }
        return ModeTile(
            title: "Heat Protection", subtitle: subtitle,
            symbol: paused ? "flame.fill" : "thermometer.medium",
            isActive: prefs.heatProtectionEnabled, tint: paused ? .red : .pink,
            action: { withAnimation(.snappy) { prefs.heatProtectionEnabled.toggle() } })
    }
}

/// Step progress for an active calibration with advance / stop controls.
private struct CalibrationRow: View {
    @ObservedObject var controller: ChargeController
    let phase: CalibrationPhase

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(phase.title).font(.footnote.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Button("Next Step") { controller.advanceCalibrationStep() }
                    .buttonStyle(.glass)
                Button("Stop", role: .destructive) { controller.stopCalibration() }
                    .buttonStyle(.glass)
                    .tint(.red)
            }
            .controlSize(.small)

            ProgressView(value: Double(phase.rawValue), total: Double(CalibrationPhase.allCases.count))
                .tint(.purple)
                .accessibilityLabel("Calibration progress")

            if phase == .holdAt100 {
                let minLeft = controller.calibrationHoldMinimumRemainingSeconds
                Text(minLeft > 0
                     ? "Holding until the gauge reports full (at least \(PopoverFormat.countdown(TimeInterval(minLeft))) more)"
                     : "Holding until the gauge reports full")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(Color.purple.opacity(0.12), in: .rect(cornerRadius: PopoverMetrics.tileRadius))
    }
}
