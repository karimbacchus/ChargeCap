//
// PopoverComponents.swift
// Shared building blocks for the popover: glass cards, tiles, segmented control.
//

import ChargeCapCore
import SwiftUI

enum PopoverMetrics {
    static let width: CGFloat = 392
    static let height: CGFloat = 720
    static let outer: CGFloat = 16
    static let spacing: CGFloat = 12
    static let cardRadius: CGFloat = 20
    static let tileRadius: CGFloat = 12
}

extension OperatingMode {
    /// Accent color that conveys the current charging state.
    var tint: Color {
        switch self {
        case .chargingToLimit, .topUp: return .green
        case .holdingAtLimit: return .blue
        case .sailing: return .cyan
        case .discharging: return .orange
        case .calibrating: return .purple
        case .heatProtectionPaused: return .red
        case .onBattery, .sleepingPaused: return .secondary
        }
    }
}

extension View {
    /// Standard Liquid Glass card surface used by the hero card and every widget.
    func glassCard(radius: CGFloat = PopoverMetrics.cardRadius) -> some View {
        glassEffect(.regular, in: .rect(cornerRadius: radius))
    }

    /// Quiet inset surface for content placed inside a glass card (never glass-on-glass).
    func insetTile(radius: CGFloat = PopoverMetrics.tileRadius) -> some View {
        background(Color.primary.opacity(0.06), in: .rect(cornerRadius: radius))
    }
}

/// A titled glass card that hosts a widget's content.
struct WidgetCard<Trailing: View, Content: View>: View {
    let title: String
    let symbol: String
    var tint: Color = .accentColor
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Label {
                    Text(title).font(.subheadline.weight(.semibold))
                } icon: {
                    Image(systemName: symbol).foregroundStyle(tint)
                }
                .labelStyle(.titleAndIcon)
                Spacer(minLength: 8)
                trailing()
            }
            content()
        }
        .padding(PopoverMetrics.outer)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

extension WidgetCard where Trailing == EmptyView {
    init(title: String, symbol: String, tint: Color = .accentColor,
         @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, symbol: symbol, tint: tint, trailing: { EmptyView() }, content: content)
    }
}

/// Label / value pair on a quiet inset surface.
struct MetricTile: View {
    let label: String
    let value: String
    var valueTint: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(valueTint ?? .primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .insetTile()
        .accessibilityElement(children: .combine)
    }
}

/// Toggle-style tile with a round symbol badge. Used by the Controls widget.
struct ModeTile: View {
    let title: String
    let subtitle: String
    let symbol: String
    let isActive: Bool
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isActive ? Color.white : tint)
                    .frame(width: 30, height: 30)
                    .background(isActive ? tint : tint.opacity(0.15), in: .circle)
                    .symbolEffect(.bounce, value: isActive)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.subheadline.weight(.medium)).lineLimit(1)
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isActive ? tint.opacity(0.14) : Color.primary.opacity(0.06), in: .rect(cornerRadius: PopoverMetrics.tileRadius))
            .contentShape(.rect(cornerRadius: PopoverMetrics.tileRadius))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isActive ? "On. \(subtitle)" : "Off. \(subtitle)")
        .accessibilityAddTraits(.isToggle)
    }
}

/// Capsule segmented control whose selection is a Liquid Glass pill that morphs between segments.
struct GlassSegmented<Value: Hashable>: View {
    struct Item: Identifiable {
        let value: Value
        let label: String
        var id: String { label }
    }

    let items: [Item]
    let selection: Value?
    let onSelect: (Value) -> Void
    @Namespace private var namespace

    var body: some View {
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 2) {
                ForEach(items) { item in
                    let isSelected = item.value == selection
                    Button {
                        withAnimation(.smooth(duration: 0.3)) { onSelect(item.value) }
                    } label: {
                        Text(item.label)
                            .font(.caption.weight(isSelected ? .semibold : .regular))
                            .monospacedDigit()
                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(isSelected ? .regular.tint(Color.accentColor).interactive() : .identity, in: .capsule)
                    .glassEffectID(isSelected ? "selection" : item.id, in: namespace)
                    .accessibilityLabel(item.label)
                    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                }
            }
            .padding(2)
            .background(Color.primary.opacity(0.06), in: .capsule)
        }
    }
}

enum PopoverFormat {
    static func duration(minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        return h > 0 ? "\(h) h \(m) min" : "\(m) min"
    }

    static func countdown(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}
