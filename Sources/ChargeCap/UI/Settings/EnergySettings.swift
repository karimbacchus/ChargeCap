import SwiftUI

struct EnergySettingsPane: View {
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        Form {
            Section {
                Picker("Threshold", selection: $prefs.energyThreshold) {
                    ForEach(EnergyThreshold.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle("Include background processes", isOn: $prefs.energyIncludeBackground)
            } header: {
                Text("Apps Using Significant Energy")
            } footer: {
                FootnoteText("Apps drawing at least \(String(format: "%.1f", prefs.energyThreshold.minimumWatts)) W on average are listed in the popover so you can quit them. Sampling only runs while the popover is open.")
            }
        }
        .settingsPane()
    }
}
