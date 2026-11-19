//
// SettingsSection.swift
// ChargeCap
//
// MIT License
//

import Combine
import SwiftUI

public enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case general = "General"
    case charging = "Charging"
    case batteryCare = "Battery Care"
    case magSafe = "MagSafe LED"
    case powerMode = "Power Mode"
    case energy = "Energy"
    case menuBar = "Menu Bar"
    case popover = "Popover"
    case schedule = "Schedule"
    case helper = "Helper"
    case about = "About"

    public var id: String { rawValue }

    public var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .charging: return "bolt.batteryblock"
        case .batteryCare: return "heart.text.square"
        case .magSafe: return "cable.connector.horizontal"
        case .powerMode: return "gauge.with.dots.needle.50percent"
        case .energy: return "leaf"
        case .menuBar: return "menubar.rectangle"
        case .popover: return "rectangle.on.rectangle"
        case .schedule: return "calendar.badge.clock"
        case .helper: return "wrench.and.screwdriver"
        case .about: return "info.circle"
        }
    }
}

/// Shared selection state so the app shell / popover can open the window on a given section.
@MainActor
public final class SettingsRouter: ObservableObject {
    public static let shared = SettingsRouter()
    @Published public var selected: SettingsSection = .general
    private init() {}
}

// MARK: - Shared row helpers

/// Slider with a trailing value label, usable inside a grouped Form.
struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    let label: (Double) -> String

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 10) {
                Slider(value: $value, in: range, step: step)
                    .frame(minWidth: 140, maxWidth: 220)
                Text(label(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 64, alignment: .trailing)
            }
        }
    }
}

extension View {
    /// Standard detail pane: grouped form, no extra chrome.
    func settingsPane() -> some View {
        formStyle(.grouped)
            .scrollContentBackground(.automatic)
    }
}

struct FootnoteText: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary)
    }
}
