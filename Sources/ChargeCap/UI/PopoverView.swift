//
// PopoverView.swift
// ChargeCap menu bar popover: header, hero card and a customizable widget stack.
//

import AppKit
import ChargeCapCore
import SwiftUI

/// Snapshot presets used by the hardware-free self test (the popover itself has no tabs).
public enum PopoverTab: String, CaseIterable, Identifiable {
    case overview, graphs, edit, everything
    public var id: String { rawValue }
}

public struct PopoverView: View {
    public static let preferredSize = NSSize(width: PopoverMetrics.width, height: PopoverMetrics.height)

    @ObservedObject private var controller = ChargeController.shared
    @ObservedObject private var prefs = Prefs.shared
    @ObservedObject private var helper = HelperClient.shared
    @ObservedObject private var scheduler = ScheduleManager.shared
    @ObservedObject private var history = HistoryStore.shared
    @ObservedObject private var energy = EnergyMonitor.shared
    @ObservedObject private var sleep = SleepControl.shared

    @State private var isEditing: Bool
    private let previewWidgets: [PopoverWidget]?

    public var onOpenSettings: () -> Void

    public init(initialTab: PopoverTab = .overview, onOpenSettings: @escaping () -> Void = {}) {
        _isEditing = State(initialValue: initialTab == .edit)
        switch initialTab {
        case .overview, .edit: previewWidgets = nil
        case .graphs: previewWidgets = [.graphs, .specifications]
        case .everything: previewWidgets = PopoverWidget.allCases
        }
        self.onOpenSettings = onOpenSettings
    }

    public var body: some View {
        VStack(spacing: PopoverMetrics.spacing) {
            PopoverHeader(controller: controller, prefs: prefs, isEditing: $isEditing, onOpenSettings: onOpenSettings)
                .padding(.horizontal, PopoverMetrics.outer)
                .padding(.top, PopoverMetrics.outer)

            ScrollView {
                GlassEffectContainer(spacing: PopoverMetrics.spacing) {
                    VStack(spacing: PopoverMetrics.spacing) {
                        HeroCard(controller: controller, prefs: prefs)

                        if isEditing {
                            WidgetEditor(prefs: prefs) { withAnimation(.snappy) { isEditing = false } }
                        } else {
                            ForEach(visibleWidgets) { widget in
                                widgetView(widget)
                                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                            }
                        }

                        NextTaskRow(scheduler: scheduler, onOpen: onOpenSettings)
                    }
                    .padding(.horizontal, PopoverMetrics.outer)
                    .padding(.vertical, 4)
                }
            }
            .scrollIndicators(.hidden)
            .scrollEdgeEffectStyle(.soft, for: .vertical)

            PopoverFooter(helper: helper, controller: controller)
                .padding(.horizontal, PopoverMetrics.outer)
                .padding(.bottom, PopoverMetrics.outer - 4)
        }
        .frame(width: PopoverMetrics.width)
        .frame(maxHeight: .infinity, alignment: .top)
        .animation(.snappy, value: visibleWidgets)
    }

    private var visibleWidgets: [PopoverWidget] {
        if let previewWidgets {
            return prefs.popoverWidgetOrder.filter(previewWidgets.contains)
        }
        return prefs.popoverWidgetOrder.filter { !prefs.hiddenPopoverWidgets.contains($0) }
    }

    @ViewBuilder
    private func widgetView(_ widget: PopoverWidget) -> some View {
        switch widget {
        case .controls: ControlsWidget(controller: controller, prefs: prefs)
        case .powerFlow: PowerFlowWidget(snapshot: controller.snapshot)
        case .specifications: SpecsWidget(snapshot: controller.snapshot, prefs: prefs)
        case .graphs: GraphsWidget(controller: controller, prefs: prefs, store: history)
        case .energyApps: EnergyAppsWidget(monitor: energy)
        case .lowPowerMode: LowPowerWidget(controller: controller, prefs: prefs)
        case .sleepControl: SleepControlWidget(sleep: sleep, prefs: prefs)
        }
    }
}
