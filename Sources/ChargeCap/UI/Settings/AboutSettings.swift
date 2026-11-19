import SwiftUI

struct AboutSettingsPane: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        if let build = info?["CFBundleVersion"] as? String { return "\(short) (\(build))" }
        return short
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 8) {
                    Image(systemName: "battery.100percent.bolt")
                        .font(.system(size: 44))
                        .foregroundStyle(.tint)
                    Text("ChargeCap").font(.title2.bold())
                    Text("Version \(version)").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            Section("License") {
                Text("ChargeCap is released under the MIT License.")
            }

            Section("Credits") {
                Text("ChargeCap is a fork of AlDente, the open-source battery charge limiter by David Wernhart, rebuilt for macOS 27 with Liquid Glass.")
                    .foregroundStyle(.secondary)
            }
        }
        .settingsPane()
    }
}
