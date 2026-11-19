import ChargeCapCore
import SwiftUI

struct MagSafeSettingsPane: View {
    @ObservedObject private var prefs = Prefs.shared
    @State private var hasLED = SMCKit.isKeyFound("ACLC")

    var body: some View {
        Form {
            if !hasLED {
                Section {
                    Label("This Mac has no controllable MagSafe LED (SMC key ACLC not found).", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Picker("LED mode", selection: $prefs.magSafeLEDMode) {
                    ForEach(MagSafeLEDMode.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Blink amber while discharging", isOn: $prefs.ledBlinkWhileDischarging)
                Toggle("Turn LED off while the Mac sleeps", isOn: $prefs.ledOffDuringSleep)
            } header: {
                Text("MagSafe LED")
            } footer: {
                FootnoteText("“Sync with ChargeCap” shows amber while charging and green while holding at the limit.")
            }
            .disabled(!hasLED)
        }
        .settingsPane()
        .onChange(of: prefs.magSafeLEDMode) { _, _ in ChargeController.shared.evaluateAndApply() }
        .onChange(of: prefs.ledBlinkWhileDischarging) { _, _ in ChargeController.shared.evaluateAndApply() }
        .onChange(of: prefs.ledOffDuringSleep) { _, _ in ChargeController.shared.evaluateAndApply() }
    }
}
