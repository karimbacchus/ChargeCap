import ChargeCapCore
import SwiftUI

struct PowerModeSettingsPane: View {
    @ObservedObject private var prefs = Prefs.shared
    @ObservedObject private var controller = ChargeController.shared

    var body: some View {
        Form {
            Section {
                Picker("Low Power Mode", selection: $prefs.lowPowerModePolicy) {
                    ForEach(LowPowerModePolicy.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("Currently") {
                    Text(controller.snapshot.isLowPowerModeEnabled ? "On" : "Off")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Low Power Mode")
            } footer: {
                FootnoteText(explanation)
            }
        }
        .settingsPane()
        .onChange(of: prefs.lowPowerModePolicy) { _, _ in ChargeController.shared.evaluateAndApply() }
    }

    private var explanation: String {
        switch prefs.lowPowerModePolicy {
        case .unmanaged: return "ChargeCap leaves Low Power Mode to macOS."
        case .alwaysOff: return "ChargeCap turns Low Power Mode off whenever it is switched on."
        case .alwaysOn: return "Low Power Mode is kept on, on battery and on the power adapter."
        case .onlyOnBattery: return "Low Power Mode is on while running on battery and off on the power adapter."
        case .onlyOnAdapter: return "Low Power Mode is on only while plugged in, and off on battery."
        }
    }
}
