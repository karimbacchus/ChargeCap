//
// EnergyMonitor.swift
// ChargeCap
//
// "Apps using significant energy": samples per-process energy via proc_pid_rusage
// (RUSAGE_INFO_V6 ri_energy_nj, CPU-time estimate as fallback), aggregates by owning
// .app bundle and publishes the heaviest ones. Samples only while observed.
//

import AppKit
import Combine
import Darwin
import Foundation

public enum EnergyThreshold: String, CaseIterable, Codable, Sendable {
    case low, medium, high

    /// Minimum average power (watts) for an app to be listed.
    public var minimumWatts: Double {
        switch self {
        case .low: return 0.3
        case .medium: return 1.0
        case .high: return 2.5
        }
    }

    public var title: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }
}

public struct EnergyApp: Identifiable, Equatable {
    /// Bundle path (e.g. /Applications/Safari.app).
    public let id: String
    public let name: String
    public let bundleIdentifier: String?
    public let icon: NSImage?
    /// Average power over the last sample interval, in watts.
    public let impact: Double
    public let pids: [Int32]
    public let isBackground: Bool
    /// System apps (under /System) are listed but cannot be quit from ChargeCap.
    public let isSystem: Bool

    public static func == (a: EnergyApp, b: EnergyApp) -> Bool {
        a.id == b.id && a.impact == b.impact && a.pids == b.pids && a.isBackground == b.isBackground
    }
}

/// Raw per-bundle sample result produced off the main actor.
private struct BundleSample: Sendable {
    let path: String
    let watts: Double
    let pids: [Int32]
}

/// Does the libproc work on a private serial queue. State is only touched on that queue.
private final class EnergySampler: @unchecked Sendable {
    private struct Prev { let start: UInt64; let energyNJ: UInt64; let cpuNS: UInt64 }

    private let queue = DispatchQueue(label: "com.chargecap.energy-sampler", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var prev: [Int32: Prev] = [:]
    private var prevTime: UInt64 = 0
    private let selfPID = getpid()
    private var timebase = mach_timebase_info_data_t()
    /// Rough package watts per fully-busy core, used only when ri_energy_nj is unavailable.
    private let wattsPerCore = 2.5

    init() { mach_timebase_info(&timebase) }

    func start(interval: TimeInterval, handler: @escaping @Sendable ([BundleSample]) -> Void) {
        queue.async {
            self.timer?.cancel()
            self.prev = [:]
            self.prevTime = 0
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + 0.5, repeating: interval, leeway: .milliseconds(500))
            t.setEventHandler {
                handler(self.sample())
            }
            self.timer = t
            t.resume()
        }
    }

    func stop() {
        queue.async {
            self.timer?.cancel()
            self.timer = nil
            self.prev = [:]
        }
    }

    private func abstimeToNS(_ t: UInt64) -> UInt64 {
        t &* UInt64(timebase.numer) / UInt64(max(timebase.denom, 1))
    }

    private func sample() -> [BundleSample] {
        let now = DispatchTime.now().uptimeNanoseconds
        let dt = prevTime == 0 ? 0 : Double(now &- prevTime) / 1e9
        prevTime = now

        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 32)
        let got = pids.withUnsafeMutableBufferPointer {
            proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<Int32>.size))
        }
        guard got > 0 else { return [] }
        pids = Array(pids.prefix(Int(got)))

        var next: [Int32: Prev] = [:]
        var byBundle: [String: (watts: Double, pids: [Int32])] = [:]
        var pathBuf = [CChar](repeating: 0, count: 4096)

        for pid in pids where pid > 1 && pid != selfPID {
            var info = rusage_info_v6()
            let rc = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
                }
            }
            guard rc == 0 else { continue }
            let cpuNS = abstimeToNS(info.ri_user_time &+ info.ri_system_time)
            let cur = Prev(start: info.ri_proc_start_abstime, energyNJ: info.ri_energy_nj, cpuNS: cpuNS)
            next[pid] = cur

            guard dt > 0, let p = prev[pid], p.start == cur.start else { continue }

            var watts: Double
            if cur.energyNJ > 0, cur.energyNJ >= p.energyNJ {
                watts = Double(cur.energyNJ - p.energyNJ) / (dt * 1e9)   // nJ / ns = W
            } else if cur.cpuNS >= p.cpuNS {
                watts = Double(cur.cpuNS - p.cpuNS) / (dt * 1e9) * wattsPerCore
            } else { continue }
            if !watts.isFinite || watts < 0 { watts = 0 }
            guard watts > 0.001 else { continue }

            let len = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
            guard len > 0 else { continue }
            let path = String(cString: pathBuf)
            guard let bundle = Self.outermostApp(in: path) else { continue }
            byBundle[bundle, default: (0, [])].watts += watts
            byBundle[bundle]!.pids.append(pid)
        }
        prev = next
        guard dt > 0 else { return [] }
        return byBundle.map { BundleSample(path: $0.key, watts: $0.value.watts, pids: $0.value.pids) }
    }

    /// Outermost "*.app" path component, e.g. /Applications/Foo.app/Contents/Frameworks/X.app/... -> /Applications/Foo.app
    static func outermostApp(in path: String) -> String? {
        let comps = path.split(separator: "/", omittingEmptySubsequences: true)
        var acc = ""
        for c in comps {
            acc += "/" + c
            if c.hasSuffix(".app") { return acc }
        }
        return nil
    }
}

@MainActor
public final class EnergyMonitor: ObservableObject {
    public static let shared = EnergyMonitor()

    @Published public private(set) var topApps: [EnergyApp] = []

    /// Minimum impact to list. Phase 2 wires this to Prefs.
    public var threshold: EnergyThreshold = .low {
        didSet { if oldValue != threshold { refilter() } }
    }
    public var includeBackgroundProcesses: Bool = false {
        didSet { if oldValue != includeBackgroundProcesses { refilter() } }
    }
    public var sampleInterval: TimeInterval = 5
    public var maxApps = 8

    private let sampler = EnergySampler()
    private var observers = 0
    private var lastSamples: [BundleSample] = []

    private init() {}

    public func startSampling() {
        observers += 1
        guard observers == 1 else { return }
        sampler.start(interval: sampleInterval) { [weak self] samples in
            Task { @MainActor [weak self] in self?.receive(samples) }
        }
    }

    public func stopSampling() {
        guard observers > 0 else { return }
        observers -= 1
        guard observers == 0 else { return }
        sampler.stop()
        lastSamples = []
        topApps = []
    }

    /// Politely asks the app to quit (never force-terminates, never touches system apps or ourselves).
    public func quit(_ app: EnergyApp) {
        guard !app.isSystem else { return }
        let me = ProcessInfo.processInfo.processIdentifier
        let pidSet = Set(app.pids)
        for running in NSWorkspace.shared.runningApplications {
            guard running.processIdentifier != me else { continue }
            let matches = pidSet.contains(running.processIdentifier)
                || running.bundleURL?.path == app.id
            if matches { running.terminate() }
        }
    }

    // MARK: - Private

    private func receive(_ samples: [BundleSample]) {
        guard observers > 0 else { return }
        lastSamples = samples
        refilter()
    }

    private func refilter() {
        let myBundle = Bundle.main.bundlePath
        var running: [String: NSRunningApplication] = [:]
        for r in NSWorkspace.shared.runningApplications {
            if let p = r.bundleURL?.path, running[p] == nil || r.activationPolicy == .regular { running[p] = r }
        }
        let minW = threshold.minimumWatts
        var apps: [EnergyApp] = []
        for s in lastSamples where s.watts >= minW && s.path != myBundle {
            let ra = running[s.path]
            let background = (ra?.activationPolicy ?? .prohibited) != .regular
            if background && !includeBackgroundProcesses { continue }
            let url = URL(fileURLWithPath: s.path)
            let name = ra?.localizedName ?? url.deletingPathExtension().lastPathComponent
            let icon = ra?.icon ?? NSWorkspace.shared.icon(forFile: s.path)
            apps.append(EnergyApp(id: s.path, name: name,
                                  bundleIdentifier: ra?.bundleIdentifier ?? Bundle(path: s.path)?.bundleIdentifier,
                                  icon: icon, impact: s.watts, pids: s.pids.sorted(),
                                  isBackground: background, isSystem: s.path.hasPrefix("/System/")))
        }
        apps.sort { $0.impact > $1.impact }
        let result = Array(apps.prefix(maxApps))
        if result != topApps { topApps = result }
    }
}
