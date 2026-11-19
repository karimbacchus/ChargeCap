//
// GraphsWidget.swift
// Swift Charts: battery level, temperature, power, max capacity and cycle count.
//

import ChargeCapCore
import Charts
import SwiftUI

private enum GraphKind: String, CaseIterable, Identifiable {
    case level = "Level", temperature = "Temp", power = "Power", capacity = "Capacity", cycles = "Cycles"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .level: return "Battery Level"
        case .temperature: return "Temperature"
        case .power: return "Power"
        case .capacity: return "Max Capacity"
        case .cycles: return "Cycle Count"
        }
    }
}

private struct LivePoint {
    let date: Date
    let percent: Double
    let temperatureC: Double
    let batteryW: Double
    let systemW: Double
    let adapterW: Double
}

struct GraphsWidget: View {
    @ObservedObject var controller: ChargeController
    @ObservedObject var prefs: Prefs
    @ObservedObject var store: HistoryStore

    @State private var kind: GraphKind = .level

    private var livePoints: [LivePoint] {
        let samples = store.samples(since: Date().addingTimeInterval(-24 * 3600))
        if samples.count >= 2 {
            return samples.map {
                LivePoint(date: $0.timestamp, percent: Double($0.percent), temperatureC: $0.temperatureC,
                          batteryW: $0.batteryW, systemW: $0.systemW, adapterW: $0.adapterW)
            }
        }
        return controller.history.map {
            LivePoint(date: $0.timestamp, percent: $0.osPercent, temperatureC: $0.temperatureC,
                      batteryW: $0.batteryWatts, systemW: $0.systemWatts, adapterW: $0.adapterWatts)
        }
    }

    var body: some View {
        WidgetCard(title: "Graphs", symbol: "chart.xyaxis.line", tint: .indigo) {
            VStack(alignment: .leading, spacing: 10) {
                GlassSegmented(
                    items: GraphKind.allCases.map { .init(value: $0, label: $0.rawValue) },
                    selection: kind
                ) { kind = $0 }

                Text(subtitle).font(.caption).foregroundStyle(.secondary)

                chart
                    .frame(height: 150)
                    .animation(.smooth, value: kind)
            }
        }
    }

    private var subtitle: String {
        switch kind {
        case .level, .temperature, .power:
            let usingStore = store.samples(since: Date().addingTimeInterval(-24 * 3600)).count >= 2
            return "\(kind.title) · " + (usingStore ? "last 24 hours" : "live session")
        case .capacity: return "Max capacity (% of design) · daily"
        case .cycles: return "Cycle count · daily"
        }
    }

    @ViewBuilder private var chart: some View {
        switch kind {
        case .level: levelChart
        case .temperature: temperatureChart
        case .power: powerChart
        case .capacity: healthChart(value: { $0.healthPercent }, unit: "%", format: "%.1f")
        case .cycles: healthChart(value: { Double($0.cycleCount) }, unit: "", format: "%.0f")
        }
    }

    private var xFormat: Date.FormatStyle {
        let pts = livePoints
        let span = (pts.last?.date.timeIntervalSince(pts.first?.date ?? Date())) ?? 0
        return span < 3 * 3600 ? .dateTime.hour().minute() : .dateTime.hour()
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Charts

    private var levelChart: some View {
        let pts = livePoints
        return Group {
            if pts.count < 2 { empty("Collecting data…") } else {
                Chart {
                    ForEach(Array(pts.enumerated()), id: \.offset) { _, p in
                        AreaMark(x: .value("Time", p.date), y: .value("Level", p.percent))
                            .foregroundStyle(LinearGradient(colors: [Color.accentColor.opacity(0.35), .clear], startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Time", p.date), y: .value("Level", p.percent))
                            .foregroundStyle(Color.accentColor)
                            .interpolationMethod(.monotone)
                    }
                    RuleMark(y: .value("Limit", prefs.chargeLimit))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(.secondary)
                        .annotation(position: .top, alignment: .trailing, spacing: 2) {
                            Text("Limit \(prefs.chargeLimit)%").font(.caption2).foregroundStyle(.secondary)
                        }
                }
                .chartYScale(domain: 0...100)
                .chartYAxis { AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) { v in
                    AxisGridLine(); AxisValueLabel { if let n = v.as(Int.self) { Text("\(n)%") } }
                } }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine(); AxisValueLabel(format: xFormat)
                } }
            }
        }
    }

    private var temperatureChart: some View {
        let pts = livePoints
        func convert(_ c: Double) -> Double { prefs.temperatureUnitFahrenheit ? c * 9 / 5 + 32 : c }
        let unit = prefs.temperatureUnitFahrenheit ? "°F" : "°C"
        return Group {
            if pts.count < 2 { empty("Collecting data…") } else {
                Chart {
                    ForEach(Array(pts.enumerated()), id: \.offset) { _, p in
                        LineMark(x: .value("Time", p.date), y: .value("Temperature", convert(p.temperatureC)))
                            .foregroundStyle(.orange)
                            .interpolationMethod(.monotone)
                    }
                    if prefs.heatProtectionEnabled {
                        RuleMark(y: .value("Max", convert(prefs.heatProtectionMaxCelsius)))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .foregroundStyle(.red.opacity(0.7))
                            .annotation(position: .top, alignment: .trailing, spacing: 2) {
                                Text("Heat limit").font(.caption2).foregroundStyle(.red.opacity(0.8))
                            }
                    }
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartYAxis { AxisMarks(position: .leading) { v in
                    AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d))\(unit)") } }
                } }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine(); AxisValueLabel(format: xFormat)
                } }
            }
        }
    }

    private var powerChart: some View {
        let pts = livePoints
        return Group {
            if pts.count < 2 { empty("Collecting data…") } else {
                Chart {
                    ForEach(Array(pts.enumerated()), id: \.offset) { _, p in
                        LineMark(x: .value("Time", p.date), y: .value("Watts", p.systemW), series: .value("Series", "System"))
                            .foregroundStyle(by: .value("Series", "System"))
                        LineMark(x: .value("Time", p.date), y: .value("Watts", p.adapterW), series: .value("Series", "Adapter"))
                            .foregroundStyle(by: .value("Series", "Adapter"))
                        LineMark(x: .value("Time", p.date), y: .value("Watts", p.batteryW), series: .value("Series", "Battery"))
                            .foregroundStyle(by: .value("Series", "Battery"))
                    }
                }
                .chartForegroundStyleScale(["System": Color.blue, "Adapter": Color.green, "Battery": Color.orange])
                .chartLegend(position: .bottom, spacing: 6)
                .chartYAxis { AxisMarks(position: .leading) { v in
                    AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text("\(Int(d)) W") } }
                } }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine(); AxisValueLabel(format: xFormat)
                } }
            }
        }
    }

    private func healthChart(value: @escaping (HealthSample) -> Double, unit: String, format: String) -> some View {
        let samples = store.healthSamples
        return Group {
            if samples.isEmpty { empty("Collecting data… (one sample per day)") } else {
                Chart {
                    ForEach(samples) { s in
                        if samples.count > 1 {
                            LineMark(x: .value("Day", s.day, unit: .day), y: .value("Value", value(s)))
                                .foregroundStyle(Color.teal)
                                .interpolationMethod(.monotone)
                        }
                        PointMark(x: .value("Day", s.day, unit: .day), y: .value("Value", value(s)))
                            .foregroundStyle(Color.teal)
                            .symbolSize(samples.count > 14 ? 0 : 30)
                    }
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartYAxis { AxisMarks(position: .leading) { v in
                    AxisGridLine(); AxisValueLabel { if let d = v.as(Double.self) { Text(String(format: format, d) + unit) } }
                } }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine(); AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                } }
            }
        }
    }
}
