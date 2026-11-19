//
// SpecsWidget.swift
// Cycle count, health, capacities, cell voltages, temperature, voltage and current.
//

import ChargeCapCore
import SwiftUI

struct SpecsWidget: View {
    let snapshot: BatterySnapshot
    @ObservedObject var prefs: Prefs

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        WidgetCard(title: "Specifications", symbol: "list.bullet.rectangle") {
            VStack(spacing: 8) {
                LazyVGrid(columns: columns, spacing: 8) {
                    MetricTile(label: "Cycle Count", value: "\(snapshot.cycleCount)")
                    MetricTile(label: "Health", value: String(format: "%.1f%%", snapshot.healthPercentage),
                               valueTint: snapshot.healthPercentage < 80 ? .orange : nil)
                    MetricTile(label: "Full Capacity", value: "\(snapshot.fullChargeCapacityMah) mAh")
                    MetricTile(label: "Design Capacity", value: "\(snapshot.designCapacityMah) mAh")
                    MetricTile(label: "Temperature", value: prefs.formatTemperature(snapshot.batteryTemperatureC),
                               valueTint: snapshot.batteryTemperatureC >= prefs.heatProtectionMaxCelsius ? .orange : nil)
                    MetricTile(label: "Voltage · Current",
                               value: String(format: "%.2f V · %.2f A", snapshot.voltageVolts, snapshot.amperageAmps))
                }

                if !snapshot.cellVoltagesMillivolts.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Cell Voltages").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Text("Δ \(snapshot.cellDeltaMillivolts) mV")
                                .font(.caption.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(snapshot.cellDeltaMillivolts < 25 ? Color.green : Color.orange)
                        }
                        HStack(spacing: 8) {
                            ForEach(Array(snapshot.cellVoltagesMillivolts.enumerated()), id: \.offset) { idx, mv in
                                VStack(spacing: 1) {
                                    Text(String(mv)).font(.callout.weight(.semibold)).monospacedDigit()
                                    Text("Cell \(idx + 1) · mV").font(.caption2).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                                .insetTile(radius: 10)
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                }
            }
        }
    }
}
