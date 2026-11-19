import AppKit
import ChargeCapCore
import SwiftUI

struct MenuBarSettingsPane: View {
    @ObservedObject private var prefs = Prefs.shared
    @ObservedObject private var controller = ChargeController.shared

    var body: some View {
        Form {
            Section("Preview") {
                HStack {
                    Spacer()
                    MenuBarPreview(style: prefs.menuBarIconStyle, readout: prefs.menuBarReadoutMode)
                    Spacer()
                }
                .padding(.vertical, 4)
            }

            Section("Icon Style") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 10) {
                    ForEach(MenuBarIconStyle.allCases) { style in
                        StyleTile(style: style, selected: prefs.menuBarIconStyle == style) {
                            prefs.menuBarIconStyle = style
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                Picker("Readout", selection: $prefs.menuBarReadoutMode) {
                    ForEach(MenuBarReadoutMode.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Tint icon yellow in Low Power Mode", isOn: $prefs.menuBarLowPowerTint)
            } header: {
                Text("Readout")
            } footer: {
                FootnoteText("The icon follows the menu bar's appearance. With text-only style the readout is shown without an icon.")
            }

            Section("Right Click") {
                Picker("Right-click action", selection: $prefs.menuBarRightClickAction) {
                    ForEach(MenuBarRightClickAction.allCases) { Text($0.title).tag($0) }
                }
            }
        }
        .settingsPane()
    }
}

private struct StyleTile: View {
    let style: MenuBarIconStyle
    let selected: Bool
    let action: () -> Void
    @ObservedObject private var controller = ChargeController.shared

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                MenuBarPreview(style: style, readout: .none, compact: true)
                Text(shortTitle)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .lineLimit(2, reservesSpace: true)
            }
            .padding(8)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.05))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 1.5)
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(style.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var shortTitle: String {
        switch style {
        case .ringGauge: return "Ring Gauge"
        case .batteryCapsule: return "Capsule"
        case .minimalBolt: return "Minimal Symbol"
        case .textOnly: return "Text Only"
        case .liveStatus: return "Live Status"
        case .macOSBattery: return "macOS Battery"
        }
    }
}

/// Mini menu-bar pill showing the real icon renderer output.
struct MenuBarPreview: View {
    let style: MenuBarIconStyle
    let readout: MenuBarReadoutMode
    var compact = false
    @ObservedObject private var prefs = Prefs.shared
    @ObservedObject private var controller = ChargeController.shared

    var body: some View {
        let image = MenuBarIconRenderer.renderStatusBarImage(
            snapshot: controller.snapshot, mode: controller.operatingMode, prefs: prefs, style: style)
        let text = MenuBarIconRenderer.readoutText(snapshot: controller.snapshot, prefs: prefs, mode: readout)
        HStack(spacing: 4) {
            if style != .textOnly {
                Image(nsImage: image)
                    .renderingMode(image.isTemplate ? .template : .original)
            }
            if !text.isEmpty || style == .textOnly {
                Text(text.isEmpty ? "\(controller.snapshot.osPercentage)%" : text)
                    .font(.system(size: 13).monospacedDigit())
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .frame(height: compact ? 26 : 30)
        .frame(minWidth: compact ? 0 : 120)
        .background(Capsule().fill(.quaternary))
    }
}

/// Dev/self-test gallery: every icon style across operating modes, light and dark.
struct MenuBarIconGallery: View {
    let snapshot: BatterySnapshot
    let modes: [(String, OperatingMode)]

    var body: some View {
        HStack(spacing: 0) {
            panel(scheme: .light)
            panel(scheme: .dark)
        }
    }

    private func panel(scheme: ColorScheme) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(MenuBarIconStyle.allCases) { style in
                HStack(spacing: 6) {
                    Text(style.rawValue).font(.caption2).frame(width: 40, alignment: .leading)
                    ForEach(modes, id: \.0) { _, mode in
                        cell(style: style, mode: mode)
                    }
                }
            }
            HStack(spacing: 6) {
                Text("tint").font(.caption2).frame(width: 40, alignment: .leading)
                cell(style: .macOSBattery, mode: .chargingToLimit(target: 80), lowPower: true)
                cell(style: .liveStatus, mode: .holdingAtLimit(limit: 80), lowPower: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(scheme == .dark ? Color.black.opacity(0.85) : Color(white: 0.93))
        .environment(\.colorScheme, scheme)
    }

    @MainActor
    private func cell(style: MenuBarIconStyle, mode: OperatingMode, lowPower: Bool = false) -> some View {
        var snap = snapshot
        snap.isLowPowerModeEnabled = lowPower
        let image = MenuBarIconRenderer.renderStatusBarImage(snapshot: snap, mode: mode, prefs: Prefs.shared, style: style)
        return Image(nsImage: image)
            .renderingMode(image.isTemplate ? .template : .original)
            .foregroundStyle(.primary)
            .frame(width: 30, height: 24)
    }
}
