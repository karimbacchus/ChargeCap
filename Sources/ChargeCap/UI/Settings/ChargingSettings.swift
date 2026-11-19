import ChargeCapCore
import SwiftUI

struct ChargingSettingsPane: View {
    @ObservedObject private var prefs = Prefs.shared
    @ObservedObject private var controller = ChargeController.shared

    var body: some View {
        Form {
            Section {
                SliderRow(
                    title: "Maximum charge",
                    value: Binding(get: { Double(prefs.chargeLimit) }, set: { prefs.chargeLimit = Int($0.rounded()) }),
                    range: Double(prefs.minAllowedChargeLimit)...100
                ) { "\(Int($0))%" }
                Toggle("Allow limits below 20%", isOn: $prefs.allowLowLimits)
            } header: {
                Text("Charge Limit")
            } footer: {
                FootnoteText("ChargeCap stops charging at this level and holds the battery there while plugged in.")
            }

            Section {
                Toggle("Sailing mode", isOn: $prefs.sailingModeEnabled)
                SliderRow(
                    title: "Sailing difference",
                    value: Binding(get: { Double(prefs.sailingDelta) }, set: { prefs.sailingDelta = Int($0.rounded()) }),
                    range: 1...30
                ) { "−\(Int($0))%" }
                .disabled(!prefs.sailingModeEnabled)
            } header: {
                Text("Sailing")
            } footer: {
                FootnoteText(prefs.sailingModeEnabled
                    ? "After reaching the limit, charging resumes only once the battery falls to \(prefs.sailingTarget)%, avoiding constant micro-charging."
                    : "When off, charging resumes as soon as the battery drops below the limit.")
            }

            Section("Top Up") {
                Toggle("Return to limit when unplugged", isOn: $prefs.topUpAutoRevertOnUnplug)
                Toggle("Return to limit at 100%", isOn: $prefs.topUpAutoRevertAt100)
            }

            Section {
                Toggle("Automatic discharge when above limit", isOn: $prefs.autoDischargeEnabled)
                Toggle("Discharge with the lid closed", isOn: $prefs.dischargeInClamshell)
            } header: {
                Text("Discharge")
            } footer: {
                FootnoteText("Discharging forces the Mac to run from the battery while plugged in. With the lid closed the Mac must stay awake, so this is off by default.")
            }

            Section {
                Toggle("Use hardware battery percentage", isOn: $prefs.useHardwarePercentage)
            } header: {
                Text("Battery Percentage")
            } footer: {
                FootnoteText("macOS shows \(controller.snapshot.osPercentage)% while the battery controller reports \(String(format: "%.1f%%", controller.snapshot.hardwarePercentage)) (\(controller.snapshot.currentCapacityMah) / \(controller.snapshot.fullChargeCapacityMah) mAh). When enabled, the limit is applied to the hardware value.")
            }
        }
        .settingsPane()
    }
}
