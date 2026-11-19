//
// OnboardingView.swift
// ChargeCap
//
// MIT License
//

import AppKit
import ChargeCapCore
import SwiftUI

extension Notification.Name {
    static let chargeCapShowOnboarding = Notification.Name("com.chargecap.showOnboarding")
}

public struct OnboardingView: View {
    enum Step: Int, CaseIterable { case welcome, helper, macOS, limit }

    @ObservedObject private var prefs = Prefs.shared
    @ObservedObject private var helper = HelperClient.shared
    @State private var step: Step
    let onFinish: () -> Void

    public static let preferredSize = CGSize(width: 520, height: 460)

    public init(initialStep: Int = 0, onFinish: @escaping () -> Void = {}) {
        _step = State(initialValue: Step(rawValue: initialStep) ?? .welcome)
        self.onFinish = onFinish
    }

    public var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .welcome: welcome
                case .helper: helperStep
                case .macOS: macOSStep
                case .limit: limitStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 36)
            .padding(.top, 28)
            .transition(.opacity)

            footer
        }
        .frame(width: Self.preferredSize.width, height: Self.preferredSize.height)
        .background(.background)
        .onAppear { helper.checkHelperStatus() }
    }

    // MARK: Steps

    private func hero(_ symbol: String, _ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 46, weight: .regular))
                .foregroundStyle(.tint)
                .frame(width: 96, height: 96)
                .glassEffect(.regular, in: .circle)
            Text(title).font(.title.bold())
            Text(subtitle).font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }

    private var welcome: some View {
        VStack(spacing: 18) {
            hero("battery.100percent.bolt", "Welcome to ChargeCap",
                 "Keep your battery healthy by capping the charge level, holding it there while plugged in, and protecting it from heat.")
            VStack(alignment: .leading, spacing: 8) {
                bullet("slider.horizontal.3", "Set a charge limit and sailing range")
                bullet("thermometer.medium", "Pause charging when the battery is hot")
                bullet("calendar.badge.clock", "Top Up, discharge, calibrate and schedule")
            }
        }
    }

    private func bullet(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol).font(.callout)
    }

    private var helperStep: some View {
        VStack(spacing: 18) {
            hero("lock.shield", "Install the Helper",
                 "Changing charging behaviour needs a small privileged helper. macOS will ask for your administrator password once.")
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: helper.isHelperConnected ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(helper.isHelperConnected ? Color.green : Color.orange)
                    Text(helper.helperStatusMessage).font(.callout)
                }
                Button(helper.helperNeedsUpdate ? "Update Helper" : (helper.isHelperConnected ? "Reinstall Helper" : "Install Helper")) {
                    helper.installOrUpdateHelper()
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            }
            .padding(14)
            .frame(maxWidth: .infinity)
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
        }
    }

    private var macOSStep: some View {
        VStack(spacing: 18) {
            hero("exclamationmark.triangle", "Turn Off macOS Charging Limits",
                 "macOS's own Optimized Battery Charging and the built-in charge limit (macOS 26.4 and later) compete with ChargeCap. Turn them off in Battery settings so only one is in control.")
            Button("Open Battery Settings") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.glass)
            .controlSize(.large)
        }
    }

    private var limitStep: some View {
        VStack(spacing: 18) {
            hero("bolt.batteryblock", "Pick a Charge Limit",
                 "80% is a good balance for daily use. You can change this any time from the menu bar.")
            VStack(spacing: 10) {
                Text("\(prefs.chargeLimit)%")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Slider(
                    value: Binding(get: { Double(prefs.chargeLimit) }, set: { prefs.chargeLimit = Int($0.rounded()) }),
                    in: Double(prefs.minAllowedChargeLimit)...100, step: 1
                )
                HStack(spacing: 8) {
                    ForEach([60, 70, 80, 90], id: \.self) { value in
                        Button("\(value)%") { prefs.chargeLimit = value }
                            .buttonStyle(.glass)
                    }
                }
            }
            .padding(14)
            .glassEffect(.regular, in: .rect(cornerRadius: 16))
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.rawValue) { s in
                    Circle()
                        .fill(s == step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }
            Spacer()
            if step != .welcome {
                Button("Back") { go(-1) }.buttonStyle(.glass)
            }
            if step == .limit {
                Button("Done") {
                    prefs.hasCompletedOnboarding = true
                    ChargeController.shared.evaluateAndApply()
                    onFinish()
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
            } else {
                Button(step == .helper || step == .macOS ? "Continue" : "Get Started") { go(1) }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    private func go(_ delta: Int) {
        guard let next = Step(rawValue: step.rawValue + delta) else { return }
        withAnimation(.snappy(duration: 0.2)) { step = next }
    }
}
