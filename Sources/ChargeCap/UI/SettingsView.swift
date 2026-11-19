//
// SettingsView.swift
// ChargeCap
//
// MIT License
//

import AppKit
import ChargeCapCore
import SwiftUI

/// Native System-Settings-style window: sidebar of sections + grouped-form detail pane.
public struct SettingsView: View {
    @ObservedObject private var router = SettingsRouter.shared

    /// - Parameter initialSection: when given, selects that section; otherwise the router's current one is kept.
    public init(initialSection: SettingsSection? = nil) {
        if let initialSection { SettingsRouter.shared.selected = initialSection }
    }

    public var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: Binding<SettingsSection?>(
                get: { router.selected },
                set: { if let new = $0 { router.selected = new } }
            )) { section in
                Label(section.rawValue, systemImage: section.symbolName)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            detail(for: router.selected)
                .navigationTitle(router.selected.rawValue)
        }
        .frame(minWidth: 720, minHeight: 520)
    }

    @ViewBuilder
    private func detail(for section: SettingsSection) -> some View {
        switch section {
        case .general: GeneralSettingsPane()
        case .charging: ChargingSettingsPane()
        case .batteryCare: BatteryCareSettingsPane()
        case .magSafe: MagSafeSettingsPane()
        case .powerMode: PowerModeSettingsPane()
        case .energy: EnergySettingsPane()
        case .menuBar: MenuBarSettingsPane()
        case .popover: PopoverSettingsPane()
        case .schedule: ScheduleSettingsPane()
        case .helper: HelperSettingsPane()
        case .about: AboutSettingsPane()
        }
    }
}
