import ChargeCapCore
import SwiftUI

struct HelperSettingsPane: View {
    @ObservedObject private var helper = HelperClient.shared
    @ObservedObject private var prefs = Prefs.shared
    @State private var diagnostics: [(key: String, type: String, hex: String)] = []

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle().fill(helper.isHelperConnected ? Color.green : Color.orange).frame(width: 8, height: 8)
                        Text(helper.isHelperConnected ? "Connected" : "Not connected")
                    }
                }
                Text(helper.helperStatusMessage).font(.callout).foregroundStyle(.secondary)
                LabeledContent("Installed version", value: helper.installedHelperVersion ?? "None")
                LabeledContent("Bundled version", value: ChargeCapConstants.helperVersion)
                if helper.helperNeedsUpdate {
                    Label("A newer helper is bundled with this app.", systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.orange)
                }
                LabeledContent("Detected key family", value: helper.detectedKeyFamily.rawValue)
            } header: {
                Text("Privileged Helper")
            } footer: {
                FootnoteText("The helper is a small root daemon that performs the SMC writes. Installing or updating asks for an administrator password.")
            }

            Section {
                Button(helper.isHelperConnected && !helper.helperNeedsUpdate ? "Reinstall Helper" : (helper.helperNeedsUpdate ? "Update Helper" : "Install Helper")) {
                    helper.installOrUpdateHelper()
                }
                Button("Check Status") { helper.checkHelperStatus() }
                Button("Uninstall Helper…", role: .destructive) {
                    helper.restoreOnQuit(keepChargeInhibited: false)
                    helper.uninstallHelper()
                }
            }

            if helper.detectedKeyFamily == .intelClassic {
                Section("Intel") {
                    Toggle("Use classic BCLM key", isOn: $prefs.useClassicIntelKey)
                }
            }

            Section {
                if diagnostics.isEmpty {
                    Text("No data").foregroundStyle(.secondary)
                } else {
                    ForEach(diagnostics, id: \.key) { row in
                        LabeledContent(row.key) {
                            Text("\(row.type)  \(row.hex)")
                                .font(.system(.callout, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
                Button("Refresh") { diagnostics = helper.readSMCDiagnostics() }
            } header: {
                Text("SMC Diagnostics (read-only)")
            }
        }
        .settingsPane()
        .onAppear {
            helper.checkHelperStatus()
            diagnostics = helper.readSMCDiagnostics()
        }
    }
}
