import SwiftUI

struct GeneralSettingsPane: View {
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch ChargeCap at login", isOn: $prefs.launchAtLogin)
            }

            Section {
                Toggle("Show notifications", isOn: $prefs.notificationsEnabled)
                Group {
                    Toggle("Charge limit reached", isOn: $prefs.notifyLimitReached)
                    Toggle("Top Up", isOn: $prefs.notifyTopUp)
                    Toggle("Discharge", isOn: $prefs.notifyDischarge)
                    Toggle("Heat Protection", isOn: $prefs.notifyHeat)
                    Toggle("Calibration", isOn: $prefs.notifyCalibration)
                    Toggle("Schedule", isOn: $prefs.notifySchedule)
                }
                .disabled(!prefs.notificationsEnabled)
            } header: {
                Text("Notifications")
            } footer: {
                FootnoteText("Choose which events are allowed to post a notification.")
            }

            Section("Display") {
                Picker("Temperature unit", selection: $prefs.temperatureUnitFahrenheit) {
                    Text("Celsius (°C)").tag(false)
                    Text("Fahrenheit (°F)").tag(true)
                }
                LabeledContent("Refresh interval") {
                    Stepper(value: $prefs.refreshIntervalSeconds, in: 2...20) {
                        Text("\(prefs.refreshIntervalSeconds) s").monospacedDigit()
                    }
                }
            }

            Section("Welcome") {
                Button("Show Onboarding Again…") {
                    NotificationCenter.default.post(name: .chargeCapShowOnboarding, object: nil)
                }
            }
        }
        .settingsPane()
    }
}
