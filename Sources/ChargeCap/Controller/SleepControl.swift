//
// SleepControl.swift
// ChargeCap
//
// Keep-awake for a chosen duration using an in-process IOPM assertion.
//

import Foundation
import IOKit.pwr_mgt
import Combine

public enum SleepControlDuration: CaseIterable, Identifiable, Sendable {
    case minutes30, hour1, hours2, hours5, indefinitely

    public var id: Self { self }

    public var title: String {
        switch self {
        case .minutes30: return "30 minutes"
        case .hour1: return "1 hour"
        case .hours2: return "2 hours"
        case .hours5: return "5 hours"
        case .indefinitely: return "Indefinitely"
        }
    }

    public var seconds: TimeInterval? {
        switch self {
        case .minutes30: return 30 * 60
        case .hour1: return 3600
        case .hours2: return 2 * 3600
        case .hours5: return 5 * 3600
        case .indefinitely: return nil
        }
    }
}

@MainActor
public final class SleepControl: ObservableObject {
    public static let shared = SleepControl()

    @Published public private(set) var isActive = false
    @Published public private(set) var endsAt: Date?
    @Published public private(set) var remaining: TimeInterval?

    /// Also prevent the display from sleeping. Applies to the next start (and live if active).
    @Published public var keepDisplayAwake = false {
        didSet { if isActive, oldValue != keepDisplayAwake { rebuildAssertions() } }
    }
    /// Stop when on battery and the level is at or below this percentage.
    public var reenableBelowPercent: Int = 20
    /// Stop as soon as the charger is unplugged.
    public var stopOnUnplug: Bool = true

    private var systemAssertion: IOPMAssertionID = 0
    private var displayAssertion: IOPMAssertionID = 0
    private var timer: Timer?
    private var wasPluggedIn: Bool?

    private init() {}

    public func start(_ duration: SleepControlDuration) {
        stop()
        rebuildAssertions()
        guard systemAssertion != 0 else { return }
        if let secs = duration.seconds {
            let end = Date().addingTimeInterval(secs)
            endsAt = end
            remaining = secs
        } else {
            endsAt = nil
            remaining = nil
        }
        isActive = true
        wasPluggedIn = nil
        if endsAt != nil { scheduleTimer() }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        releaseAssertions()
        isActive = false
        endsAt = nil
        remaining = nil
        wasPluggedIn = nil
    }

    /// Called by the controller every tick.
    public func evaluate(batteryPercent: Int, isPluggedIn: Bool) {
        guard isActive else { return }
        if let end = endsAt, Date() >= end { stop(); return }
        if !isPluggedIn && batteryPercent <= reenableBelowPercent { stop(); return }
        if stopOnUnplug, wasPluggedIn == true, !isPluggedIn { stop(); return }
        wasPluggedIn = isPluggedIn
    }

    // MARK: - Private

    private func rebuildAssertions() {
        releaseAssertions()
        var id: IOPMAssertionID = 0
        if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                       IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                       "ChargeCap Sleep Control" as CFString, &id) == kIOReturnSuccess {
            systemAssertion = id
        }
        if keepDisplayAwake {
            var did: IOPMAssertionID = 0
            if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                           IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                           "ChargeCap Sleep Control (display)" as CFString, &did) == kIOReturnSuccess {
                displayAssertion = did
            }
        }
    }

    private func releaseAssertions() {
        if systemAssertion != 0 { IOPMAssertionRelease(systemAssertion); systemAssertion = 0 }
        if displayAssertion != 0 { IOPMAssertionRelease(displayAssertion); displayAssertion = 0 }
    }

    private func scheduleTimer() {
        timer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        guard isActive else { return }
        if let end = endsAt {
            let left = end.timeIntervalSinceNow
            if left <= 0 { stop(); return }
            remaining = left
        }
    }
}
