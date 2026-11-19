//
// LowPowerWidget.swift
// Low Power Mode policy picker and current state.
//

import ChargeCapCore
import SwiftUI

struct LowPowerWidget: View {
    @ObservedObject var controller: ChargeController
    @ObservedObject var prefs: Prefs

    var body: some View {
        let on = controller.snapshot.isLowPowerModeEnabled
        WidgetCard(title: "Low Power Mode", symbol: on ? "bolt.fill" : "bolt", tint: .yellow, trailing: {
            Text(on ? "On" : "Off")
                .font(.caption.weight(.semibold))
                .foregroundStyle(on ? Color.black : .secondary)
                .padding(.horizontal, 10).padding(.vertical, 3)
                .background(on ? Color.yellow : Color.primary.opacity(0.08), in: .capsule)
                .accessibilityLabel("Low Power Mode is \(on ? "on" : "off")")
        }, content: {
            HStack {
                Text("Mode").font(.footnote).foregroundStyle(.secondary)
                Spacer()
                Picker("Low Power Mode", selection: $prefs.lowPowerModePolicy) {
                    ForEach(LowPowerModePolicy.allCases) { policy in
                        Text(policy.title).tag(policy)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }
        })
        .onChange(of: prefs.lowPowerModePolicy) { _, _ in controller.evaluateAndApply() }
    }
}
