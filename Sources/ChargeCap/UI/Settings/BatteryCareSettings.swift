import ChargeCapCore
import SwiftUI

struct BatteryCareSettingsPane: View {
    @ObservedObject private var prefs = Prefs.shared
    @ObservedObject private var controller = ChargeController.shared

    var body: some View {
        Form {
            Section {
                Toggle("Pause charging when hot", isOn: $prefs.heatProtectionEnabled)
                SliderRow(title: "Maximum temperature", value: $prefs.heatProtectionMaxCelsius, range: 25...45, step: 0.5) {
                    prefs.formatTemperature($0)
                }
                .disabled(!prefs.heatProtectionEnabled)
            } header: {
                Text("Heat Protection")
            } footer: {
                FootnoteText("Battery is \(prefs.formatTemperature(controller.snapshot.batteryTemperatureC)) now. Charging stays paused for at least 5 minutes and resumes after cooling down. Disabled while calibrating.")
            }

            Section {
                LabeledContent("Status") {
                    Text(controller.isCalibrating ? controller.calibrationPhase?.title ?? "Running" : "Not running")
                        .foregroundStyle(.secondary)
                }
                if controller.isCalibrating {
                    Button("Stop Calibration", role: .destructive) { controller.stopCalibration() }
                } else {
                    Button("Start Calibration") { controller.startCalibration() }
                }
            } header: {
                Text("Calibration")
            } footer: {
                FootnoteText("Calibration recalibrates the battery gauge: charge to 100%, discharge to 10%, charge to 100% again, hold until the battery reports full, then return to your limit. Keep the Mac plugged in and awake; it can take several hours.")
            }

            Section("Sleep") {
                Toggle("Stop charging when sleeping", isOn: $prefs.stopChargingWhenSleeping)
                Toggle("Disable sleep until the limit is reached", isOn: $prefs.disableSleepUntilChargeLimit)
                Toggle("Stop charging when ChargeCap is closed", isOn: $prefs.stopChargingWhenAppClosed)
            }

            Section {
                SliderRow(
                    title: "Re-enable sleep below",
                    value: Binding(get: { Double(prefs.sleepControlReenableBelowPercent) }, set: { prefs.sleepControlReenableBelowPercent = Int($0.rounded()) }),
                    range: 5...90
                ) { "\(Int($0))%" }
                Toggle("Stop when unplugged", isOn: $prefs.sleepControlStopOnUnplug)
                Toggle("Keep display awake", isOn: $prefs.sleepControlKeepDisplayAwake)
            } header: {
                Text("Sleep Control Defaults")
            } footer: {
                FootnoteText("Sleep Control keeps your Mac awake for a chosen duration from the menu bar. These options decide when it ends early.")
            }
        }
        .settingsPane()
    }
}
