//
// PopoverChrome.swift
// Header, helper banner / status footer, schedule row and the widget editor.
//

import AppKit
import ChargeCapCore
import SwiftUI

struct PopoverHeader: View {
    @ObservedObject var controller: ChargeController
    @ObservedObject var prefs: Prefs
    @Binding var isEditing: Bool
    var onOpenSettings: () -> Void

    var body: some View {
        let mode = controller.operatingMode
        HStack(spacing: 10) {
            Image(systemName: mode.symbolName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(mode.tint)
                .frame(width: 34, height: 34)
                .glassEffect(.regular, in: .circle)
                .symbolEffect(.bounce, value: mode.badgeText)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text("ChargeCap").font(.headline)
                Text(mode.badgeText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 8)

            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Button(action: onOpenSettings) { Image(systemName: "gearshape") }
                        .help("Settings (⌘,)")
                        .accessibilityLabel("Open Settings")
                    Menu {
                        Button { controller.refreshNow() } label: { Label("Refresh Now", systemImage: "arrow.clockwise") }
                        Button { withAnimation(.snappy) { isEditing.toggle() } } label: {
                            Label(isEditing ? "Done Editing Widgets" : "Edit Widgets…", systemImage: "rectangle.3.group")
                        }
                        Divider()
                        Button { onOpenSettings() } label: { Label("Settings…", systemImage: "gearshape") }
                        Button { NSApp.terminate(nil) } label: { Label("Quit ChargeCap", systemImage: "power") }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .menuIndicator(.hidden)
                    .accessibilityLabel("More")
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
            }
        }
    }
}

/// Bottom strip: helper install / update banner, otherwise a quiet status line.
struct PopoverFooter: View {
    @ObservedObject var helper: HelperClient
    @ObservedObject var controller: ChargeController

    var body: some View {
        if !helper.isHelperConnected || helper.helperNeedsUpdate {
            banner
        } else {
            HStack(spacing: 6) {
                Circle().fill(.green).frame(width: 6, height: 6)
                Text(controller.lastActionSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 4)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Status: \(controller.lastActionSummary)")
        }
    }

    private var banner: some View {
        let update = helper.isHelperConnected && helper.helperNeedsUpdate
        return HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .symbolEffect(.pulse)
            VStack(alignment: .leading, spacing: 1) {
                Text(update ? "Helper update required" : "Helper not installed")
                    .font(.subheadline.weight(.semibold))
                Text(update ? "Update to keep charge control working." : helper.helperStatusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            Button(update ? "Update" : "Install") { helper.installOrUpdateHelper() }
                .buttonStyle(.glassProminent)
                .controlSize(.small)
        }
        .padding(12)
        .glassEffect(.regular.tint(Color.orange.opacity(0.25)), in: .rect(cornerRadius: 16))
    }
}

/// Read-only "next scheduled task" row; tapping opens Settings.
struct NextTaskRow: View {
    @ObservedObject var scheduler: ScheduleManager
    var onOpen: () -> Void

    var body: some View {
        let next = scheduler.nextUpcomingTask
        Button(action: onOpen) {
            HStack(spacing: 10) {
                Image(systemName: "calendar.badge.clock").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(next?.task.name ?? "No scheduled tasks").font(.subheadline).lineLimit(1)
                    Text(next.map { Self.describe($0.date) } ?? "Add tasks in Settings")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(radius: 16)
            .contentShape(.rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Next scheduled task")
        .accessibilityHint("Opens Settings")
    }

    private static func describe(_ date: Date) -> String {
        let cal = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if cal.isDateInToday(date) { return "Today at \(time)" }
        if cal.isDateInTomorrow(date) { return "Tomorrow at \(time)" }
        return date.formatted(.dateTime.weekday(.wide).month().day()) + " at \(time)"
    }
}

/// Inline editor: show / hide and reorder the widget stack.
struct WidgetEditor: View {
    @ObservedObject var prefs: Prefs
    var onDone: () -> Void

    var body: some View {
        WidgetCard(title: "Edit Widgets", symbol: "rectangle.3.group", trailing: {
            Button("Done", action: onDone).buttonStyle(.glassProminent).controlSize(.small)
        }, content: {
            VStack(spacing: 6) {
                ForEach(Array(prefs.popoverWidgetOrder.enumerated()), id: \.element) { index, widget in
                    let hidden = prefs.hiddenPopoverWidgets.contains(widget)
                    HStack(spacing: 8) {
                        Button {
                            withAnimation(.snappy) {
                                if hidden { prefs.hiddenPopoverWidgets.remove(widget) }
                                else { prefs.hiddenPopoverWidgets.insert(widget) }
                            }
                        } label: {
                            Image(systemName: hidden ? "eye.slash" : "eye")
                                .contentTransition(.symbolEffect(.replace))
                                .frame(width: 22)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(hidden ? Color.secondary : Color.accentColor)
                        .accessibilityLabel(hidden ? "Show \(widget.title)" : "Hide \(widget.title)")

                        Text(widget.title)
                            .font(.subheadline)
                            .foregroundStyle(hidden ? .secondary : .primary)
                            .lineLimit(1)
                        Spacer()
                        Button { move(index, by: -1) } label: { Image(systemName: "chevron.up") }
                            .disabled(index == 0)
                            .accessibilityLabel("Move \(widget.title) up")
                        Button { move(index, by: 1) } label: { Image(systemName: "chevron.down") }
                            .disabled(index == prefs.popoverWidgetOrder.count - 1)
                            .accessibilityLabel("Move \(widget.title) down")
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .controlSize(.small)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .insetTile()
                }
            }
        })
    }

    private func move(_ index: Int, by delta: Int) {
        var order = prefs.popoverWidgetOrder
        let target = index + delta
        guard order.indices.contains(index), order.indices.contains(target) else { return }
        withAnimation(.snappy) {
            order.swapAt(index, target)
            prefs.popoverWidgetOrder = order
        }
    }
}
