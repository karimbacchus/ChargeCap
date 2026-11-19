//
// HistoryStore.swift
// ChargeCap
//
// Persisted telemetry history: one sample per minute for 7 days, plus one battery-health
// sample per calendar day kept forever. Stored as JSON in Application Support.
//

import ChargeCapCore
import Combine
import Foundation

public struct HistorySample: Codable, Identifiable, Equatable, Sendable {
    public var timestamp: Date
    public var percent: Int
    public var hwPercent: Double
    public var temperatureC: Double
    public var batteryW: Double
    public var systemW: Double
    public var adapterW: Double
    public var isCharging: Bool
    public var isPluggedIn: Bool
    public var limit: Int

    public var id: Date { timestamp }
}

public struct HealthSample: Codable, Identifiable, Equatable, Sendable {
    /// Start of the calendar day.
    public var day: Date
    public var fullChargeCapacityMah: Int
    public var designCapacityMah: Int
    public var healthPercent: Double
    public var cycleCount: Int

    public var id: Date { day }
}

@MainActor
public final class HistoryStore: ObservableObject {
    public static let shared = HistoryStore()

    public static let sampleInterval: TimeInterval = 60
    public static let sampleRetention: TimeInterval = 7 * 24 * 3600

    @Published public private(set) var samples: [HistorySample] = []
    @Published public private(set) var healthSamples: [HealthSample] = []

    private let directory: URL
    private let ioQueue = DispatchQueue(label: "com.chargecap.history-io", qos: .utility)
    private var writePending = false
    private var lastSampleTime: Date?

    private init() {
        var dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        dir.appendPathComponent("ChargeCap", isDirectory: true)
        if Prefs.devMode { dir.appendPathComponent("Dev", isDirectory: true) }
        self.directory = dir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        samples = Self.load([HistorySample].self, from: dir.appendingPathComponent("samples.json")) ?? []
        healthSamples = Self.load([HealthSample].self, from: dir.appendingPathComponent("health.json")) ?? []
        lastSampleTime = samples.last?.timestamp
        prune(now: Date())
    }

    // MARK: - Queries

    public func samples(since date: Date) -> [HistorySample] {
        // Samples are appended chronologically; binary search the first index >= date.
        var lo = 0, hi = samples.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if samples[mid].timestamp < date { lo = mid + 1 } else { hi = mid }
        }
        return Array(samples[lo...])
    }

    // MARK: - Recording

    /// Records a sample if at least a minute has passed; also keeps today's health sample current.
    public func record(snapshot: BatterySnapshot, limit: Int, now: Date = Date()) {
        recordHealth(snapshot: snapshot, now: now)

        if let last = lastSampleTime, now.timeIntervalSince(last) < Self.sampleInterval { return }
        lastSampleTime = now
        samples.append(HistorySample(
            timestamp: now,
            percent: snapshot.osPercentage,
            hwPercent: snapshot.hardwarePercentage,
            temperatureC: snapshot.batteryTemperatureC,
            batteryW: snapshot.batteryPowerWatts,
            systemW: snapshot.systemLoadWatts,
            adapterW: snapshot.adapterInputWatts,
            isCharging: snapshot.isCharging,
            isPluggedIn: snapshot.isPluggedIn,
            limit: limit
        ))
        prune(now: now)
        scheduleWrite()
    }

    /// Creates or refreshes today's health sample (called at launch and on every record).
    public func recordHealth(snapshot: BatterySnapshot, now: Date = Date()) {
        guard snapshot.fullChargeCapacityMah > 0 else { return }
        let day = Calendar.current.startOfDay(for: now)
        let sample = HealthSample(
            day: day,
            fullChargeCapacityMah: snapshot.fullChargeCapacityMah,
            designCapacityMah: snapshot.designCapacityMah,
            healthPercent: snapshot.healthPercentage,
            cycleCount: snapshot.cycleCount
        )
        if let idx = healthSamples.lastIndex(where: { $0.day == day }) {
            guard healthSamples[idx] != sample else { return }
            healthSamples[idx] = sample
        } else {
            healthSamples.append(sample)
        }
        scheduleWrite()
    }

    private func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.sampleRetention)
        if let first = samples.first, first.timestamp < cutoff {
            samples.removeAll { $0.timestamp < cutoff }
        }
    }

    // MARK: - Persistence

    private static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(T.self, from: data)
    }

    /// Debounced: at most one write per 2 minutes, performed off the main thread.
    private func scheduleWrite() {
        guard !writePending else { return }
        writePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
            Task { @MainActor in self?.flush() }
        }
    }

    /// Writes both files now (atomically, on the I/O queue). Call on quit with `wait: true`.
    public func flush(wait: Bool = false) {
        writePending = false
        let samplesCopy = samples
        let healthCopy = healthSamples
        let dir = directory
        let work = {
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            if let data = try? enc.encode(samplesCopy) {
                try? data.write(to: dir.appendingPathComponent("samples.json"), options: .atomic)
            }
            if let data = try? enc.encode(healthCopy) {
                try? data.write(to: dir.appendingPathComponent("health.json"), options: .atomic)
            }
        }
        if wait { ioQueue.sync(execute: work) } else { ioQueue.async(execute: work) }
    }
}
