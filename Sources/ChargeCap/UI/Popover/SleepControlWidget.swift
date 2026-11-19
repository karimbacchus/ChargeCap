//
// SleepControlWidget.swift
// Keep the Mac awake for a duration; re-enables sleep at a battery level or on unplug.
//

import ChargeCapCore
import SwiftUI

struct SleepControlWidget: View {
    @ObservedObject var sleep: SleepControl
    @ObservedObject var prefs: Prefs

    var body: some View {
        WidgetCard(title: "Sleep Control", symbol: sleep.isActive ? "moon.zzz.fill" : "moon.zzz", tint: .indigo, trailing: {
            if sleep.isActive {
                Button("Stop") { withAnimation(.snappy) { sleep.stop() } }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
        }, content: {
            VStack(alignment: .leading, spacing: 8) {
                if sleep.isActive {
                    HStack(spacing: 8) {
                        Image(systemName: "cup.and.saucer.fill").foregroundStyle(.indigo)
                            .symbolEffect(.pulse)
                        if let end = sleep.endsAt {
                            Text("Awake for ") + Text(end, style: .timer).monospacedDigit()
                        } else {
                            Text("Awake until stopped")
                        }
                        Spacer()
                    }
                    .font(.callout.weight(.medium))
                } else {
                    HStack {
                        Text("Keep Mac awake").font(.footnote).foregroundStyle(.secondary)
                        Spacer()
                        Menu {
                            ForEach(SleepControlDuration.allCases) { d in
                                Button(d.title) { withAnimation(.snappy) { sleep.start(d) } }
                            }
                        } label: {
                            Label("Duration", systemImage: "timer")
                        }
                        .menuStyle(.button)
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .fixedSize()
                    }
                }

                HStack {
                    Text("Keep display awake too").font(.footnote)
                    Spacer()
                    Toggle("Keep display awake", isOn: $prefs.sleepControlKeepDisplayAwake)
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                }

                Text(footnote).font(.caption2).foregroundStyle(.secondary)
            }
        })
    }

    private var footnote: String {
        var text = "Sleep is re-enabled when on battery below \(prefs.sleepControlReenableBelowPercent)%"
        if prefs.sleepControlStopOnUnplug { text += " or when the adapter is unplugged" }
        return text + "."
    }
}
