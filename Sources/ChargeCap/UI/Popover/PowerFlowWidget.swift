//
// PowerFlowWidget.swift
// Adapter -> system / battery routing with live watts and adapter details.
//

import ChargeCapCore
import SwiftUI

struct PowerFlowWidget: View {
    let snapshot: BatterySnapshot

    var body: some View {
        WidgetCard(title: "Power Flow", symbol: "bolt.horizontal.circle.fill", tint: .green) {
            VStack(spacing: 12) {
                HStack(spacing: 6) {
                    node("Adapter", watts: snapshot.adapterInputWatts, symbol: "powerplug.fill",
                         tint: snapshot.adapterInputWatts > 0.2 ? .green : .secondary)
                    arrow(active: snapshot.adapterInputWatts > 0.2)
                    node("System", watts: snapshot.systemLoadWatts, symbol: "laptopcomputer", tint: .blue)
                    arrow(active: abs(snapshot.batteryPowerWatts) > 0.3, reversed: snapshot.batteryPowerWatts < 0)
                    node("Battery", watts: snapshot.batteryPowerWatts, symbol: "battery.100percent",
                         tint: snapshot.batteryPowerWatts > 0.3 ? .green : (snapshot.batteryPowerWatts < -0.3 ? .orange : .cyan),
                         signed: true)
                }

                VStack(spacing: 6) {
                    detailRow("Adapter", adapterText, symbol: "bolt.badge.clock")
                    if snapshot.isPluggedIn {
                        detailRow("Negotiated", String(format: "%.1f V · %.2f A", snapshot.adapterNegotiatedVolts, snapshot.adapterNegotiatedAmps), symbol: "waveform.path.ecg")
                    }
                    detailRow("USB-C Out", String(format: "%.1f W", snapshot.usbExternalOutWatts), symbol: "cable.connector")
                }
            }
        }
    }

    private var adapterText: String {
        guard snapshot.isPluggedIn else { return "Not connected" }
        let name = snapshot.adapterName.isEmpty ? "Power Adapter" : snapshot.adapterName
        return snapshot.adapterRatedWatts > 0 ? "\(name) · \(snapshot.adapterRatedWatts) W" : name
    }

    private func node(_ title: String, watts: Double, symbol: String, tint: Color, signed: Bool = false) -> some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint)
                .symbolEffect(.pulse, isActive: abs(watts) > 0.3)
            Text(signed ? String(format: "%+.1f W", watts) : String(format: "%.1f W", watts))
                .font(.system(.callout, design: .rounded, weight: .bold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .insetTile()
        .accessibilityElement(children: .combine)
    }

    private func arrow(active: Bool, reversed: Bool = false) -> some View {
        Image(systemName: reversed ? "chevron.left" : "chevron.right")
            .font(.caption.weight(.bold))
            .foregroundStyle(active ? Color.accentColor : Color.secondary.opacity(0.5))
            .symbolEffect(.variableColor.iterative, isActive: active)
            .accessibilityHidden(true)
    }

    private func detailRow(_ label: String, _ value: String, symbol: String) -> some View {
        HStack {
            Label(label, systemImage: symbol).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit().lineLimit(1)
        }
        .font(.footnote)
        .accessibilityElement(children: .combine)
    }
}
