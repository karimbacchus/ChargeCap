//
// EnergyAppsWidget.swift
// Apps using significant energy, with a Quit button per app.
//

import ChargeCapCore
import SwiftUI

struct EnergyAppsWidget: View {
    @ObservedObject var monitor: EnergyMonitor

    var body: some View {
        WidgetCard(title: "Apps Using Significant Energy", symbol: "bolt.badge.clock.fill", tint: .orange) {
            VStack(spacing: 6) {
                if monitor.topApps.isEmpty {
                    Label("No apps are using significant energy", systemImage: "checkmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                } else {
                    ForEach(monitor.topApps) { app in
                        row(app)
                    }
                }
            }
        }
        // Sampling is only active while the widget is on screen.
        .onAppear { monitor.startSampling() }
        .onDisappear { monitor.stopSampling() }
    }

    private func row(_ app: EnergyApp) -> some View {
        HStack(spacing: 10) {
            Group {
                if let icon = app.icon {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    Image(systemName: "app.dashed").resizable().scaledToFit().foregroundStyle(.secondary)
                }
            }
            .frame(width: 26, height: 26)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(app.name).font(.subheadline).lineLimit(1)
                HStack(spacing: 4) {
                    Circle().fill(level(app.impact).color).frame(width: 6, height: 6)
                    Text(level(app.impact).title).font(.caption2).foregroundStyle(.secondary)
                    Text(String(format: "%.1f W", app.impact)).font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 4)
            Button("Quit") { monitor.quit(app) }
                .buttonStyle(.glass)
                .controlSize(.small)
                .disabled(app.isSystem)
                .accessibilityLabel("Quit \(app.name)")
        }
    }

    private func level(_ watts: Double) -> (title: String, color: Color) {
        if watts >= EnergyThreshold.high.minimumWatts { return ("High", .red) }
        if watts >= EnergyThreshold.medium.minimumWatts { return ("Medium", .orange) }
        return ("Low", .yellow)
    }
}
