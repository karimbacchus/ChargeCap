//
// HeroCard.swift
// Big percentage, hardware %, state line, level bar, limit slider and presets.
//

import ChargeCapCore
import SwiftUI

struct HeroCard: View {
    @ObservedObject var controller: ChargeController
    @ObservedObject var prefs: Prefs

    private var snap: BatterySnapshot { controller.snapshot }
    private var tint: Color { controller.operatingMode.tint }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(primaryPercentText)
                    .font(.system(size: 46, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                    .accessibilityLabel("Battery \(primaryPercentText)")
                Text(secondaryPercentText)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.08), in: .capsule)
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 0) {
                    Text("LIMIT").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Text("\(prefs.chargeLimit)%")
                        .font(.system(.title2, design: .rounded, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(Color.accentColor)
                        .contentTransition(.numericText())
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Charge limit \(prefs.chargeLimit) percent")
            }

            stateLine

            levelBar

            HStack(spacing: 8) {
                Slider(
                    value: Binding(
                        get: { Double(prefs.chargeLimit) },
                        set: { controller.setChargeLimit(Int($0.rounded())) }
                    ),
                    in: Double(prefs.minAllowedChargeLimit)...100,
                    step: 1
                )
                .accessibilityLabel("Charge limit")
                .accessibilityValue("\(prefs.chargeLimit) percent")

                Button {
                    controller.setChargeLimit(max(prefs.minAllowedChargeLimit, prefs.chargeLimit - 1))
                } label: { Image(systemName: "minus") }
                .accessibilityLabel("Lower limit by 1 percent")
                Button {
                    controller.setChargeLimit(min(100, prefs.chargeLimit + 1))
                } label: { Image(systemName: "plus") }
                .accessibilityLabel("Raise limit by 1 percent")
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.small)

            GlassSegmented(
                items: prefs.quickPresets.map { .init(value: $0, label: "\($0)%") },
                selection: controller.isTopUpActive ? nil : prefs.chargeLimit
            ) { preset in
                controller.isTopUpActive = false
                controller.setChargeLimit(preset)
            }
        }
        .padding(PopoverMetrics.outer)
        .glassCard(radius: 24)
    }

    // MARK: Pieces

    private var primaryPercentText: String {
        prefs.useHardwarePercentage ? String(format: "%.1f%%", snap.hardwarePercentage) : "\(snap.osPercentage)%"
    }

    private var secondaryPercentText: String {
        prefs.useHardwarePercentage ? "macOS \(snap.osPercentage)%" : String(format: "HW %.1f%%", snap.hardwarePercentage)
    }

    private var stateLine: some View {
        HStack(spacing: 6) {
            Image(systemName: stateSymbol)
                .foregroundStyle(tint)
                .symbolEffect(.pulse, isActive: snap.isCharging)
            Text(stateText)
                .lineLimit(1)
            Spacer(minLength: 4)
            Label(prefs.formatTemperature(snap.batteryTemperatureC), systemImage: "thermometer.medium")
                .foregroundStyle(snap.batteryTemperatureC >= prefs.heatProtectionMaxCelsius ? Color.orange : .secondary)
                .monospacedDigit()
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private var stateSymbol: String {
        if snap.isCharging { return "bolt.fill" }
        if snap.isPluggedIn { return "powerplug.fill" }
        return "battery.50percent"
    }

    private var stateText: String {
        var text: String
        if snap.isCharging { text = "Charging" }
        else if snap.isFullyCharged { text = "Fully charged" }
        else if snap.isPluggedIn { text = "Plugged in, not charging" }
        else { text = "On battery" }
        if let minutes = snap.timeRemainingMinutes, minutes > 0, minutes < 24 * 60 {
            if snap.isCharging { text += " · \(PopoverFormat.duration(minutes: minutes)) to full" }
            else if !snap.isPluggedIn { text += " · \(PopoverFormat.duration(minutes: minutes)) left" }
        }
        return text
    }

    private var levelBar: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let level = CGFloat(min(100, max(0, snap.percentage(useHardware: prefs.useHardwarePercentage)))) / 100
            let limitX = w * CGFloat(prefs.chargeLimit) / 100
            let sailX = w * CGFloat(prefs.sailingTarget) / 100
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                if prefs.sailingModeEnabled && prefs.sailingTarget < prefs.chargeLimit {
                    Rectangle().fill(Color.cyan.opacity(0.25))
                        .frame(width: max(2, limitX - sailX)).offset(x: sailX)
                }
                Capsule().fill(tint.gradient).frame(width: max(10, w * level))
                Capsule().fill(Color.primary)
                    .frame(width: 3, height: 14)
                    .offset(x: max(0, min(w - 3, limitX - 1.5)))
            }
            .animation(.smooth, value: level)
        }
        .frame(height: 10)
        .accessibilityHidden(true)
    }
}
