# ChargeCap Improvement Plan

Author: Claude (Opus 5.5) · 2026-11-18 · Implemented by Sonnet sub-agents in phases.

Backup of the pre-existing uncommitted Gemini work: `git stash list` → `stash@{0}` ("pre-claude snapshot").

Build: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -c debug --arch arm64`
(the CommandLineTools toolchain lacks the SwiftUI macro plugin; `make` sets this automatically).

**Hard rule for every agent: never write to the SMC, never run the helper, never run `make run`,
`make test`/`--selftest` (until Phase 2 removes hardware access from SelfTest), `sudo`, `pmset` with
set arguments, or `launchctl`. This Mac (M5 Pro, macOS 27.3) runs the installed ChargeCap and its
helper; leave both alone. Building is fine. `--status` is read-only and fine.**

---

## 1. Audit findings (what's wrong today)

### Security / safety
1. **Root helper accepts any XPC client.** `HelperXPCDelegate` returns `true` for every connection, and
   `setSMCBytes(key:bytes:)` writes *any* SMC key as root. Any local process can drive the SMC.
2. `setSMCBytes`/`readSMCBytes` have no key allowlist.
3. Admin-install shell string interpolates bundle paths inside single quotes without escaping.
4. `make test` / `--selftest` runs the real `ChargeController`, which sends real SMC writes through
   the installed helper — running the tests toggles charging on the user's Mac.

### Correctness
5. The controller re-sends every SMC write (charging, discharge, LED, BCLM) via XPC **every 3 s**,
   and `HelperClient` duplicates writes (sends `CBTC`/`CHIE` via `setSMCBytes` *and* via
   `setChargingEnabled`). Writes must be de-duplicated and re-asserted only on change, on wake,
   on helper reconnect, every 60 s, or when telemetry shows divergence.
6. `installHelper()` registers `SMAppService.daemon` and immediately checks `isHelperConnected`,
   which is set asynchronously, so it always falls through to the admin prompt. Both paths use the
   same launchd label → potential collision.
7. On quit, `resetAll`/`setChargingEnabled(false)` are async XPC calls; the process can exit before
   they're delivered. Needs synchronous proxy with a timeout.
8. Notifications are never authorized (`requestAuthorization` is never called) → none are shown.
9. Heat-protection paused LED writes `0x02` (not a known ACLC value). Known ACLC values:
   `0x00` system, `0x01` off, `0x03` green, `0x04` amber, `0x05` error-once, `0x06` slow blink,
   `0x07` fast blink.
10. Calibration holds a fixed 1 h at 100%; current AlDente ends the hold when the gauge reports
    FullyCharged, discharges to 10% (not 15%), and disables heat protection during calibration.
11. Calibration / Top Up / discharge state is lost on app restart.
12. Discharge doesn't account for lid-closed (clamshell) state; manual discharge isn't cancelled on unplug.
13. Telemetry history is in-memory only (120 points ≈ 6 min) → no real Stats.

### SMC keys on this Mac (M5 Pro, macOS 27.3, probed read-only)
Present: `CHIE`(hex_), `CHIB`, `CHIC`, `CHCE`, `CHCC`, `CBTC`(ui8), `ACLC`, `TB0T–TB2T`(flt),
`B0AT`, `BC1V–BC3V`, `B0RM/B0FC/B0AV/B0AC`. Absent: `CHTE`, `CH0B/C/I/J`, `BCLM`, `BFCL`.
Keep the existing multi-family write logic (it is what currently works for the user), just
centralise it in the helper and dedupe it.

## 2. Feature parity targets (AlDente Pro, Nov 2026)

| AlDente feature | ChargeCap today | Plan |
|---|---|---|
| Charge limiter, Discharge, Auto discharge, Top Up, Sailing | ✅ | keep; fix state persistence |
| Heat Protection | ✅ (°C hysteresis) | + 5 min minimum pause, disabled during calibration, default 35 °C for new installs |
| Calibration Mode | ✅ (fixed 1 h hold, 15%) | 10% floor, hold-until-full, persisted, schedulable |
| Hardware battery % | ✅ | keep as display + optional control |
| MagSafe LED | ✅ | + blink amber while discharging, LED off while sleeping |
| Disable sleep until limit / Stop charging when sleeping / when app closed | ✅ | fix lifecycle (sync on quit, re-assert on wake) |
| **Sleep Control** (keep awake for duration, re-enable at X% or unplug) | ❌ | new |
| **Low Power Mode control** (always on/off, only battery, only adapter) | ❌ | new (helper runs `pmset`) |
| **Apps using significant energy** (+ Quit) | ❌ | new |
| Power Flow | ✅ | keep, polish |
| **Stats / history graphs** (level, temp, power, max capacity, cycles) | partial, in-memory | persisted HistoryStore + Swift Charts |
| Schedule (+Low Power Mode actions, task history, catch-up) | partial | extend |
| Shortcuts (get %, limit, state, temp, pause, LED, LPM, discharge, top-up, calibrate) | partial | extend |
| Menu bar: live status icon, macOS battery style, extra items, update interval, right-click action, LPM tint | partial | extend |
| Popover customization (widget visibility/order) | ❌ | new |
| Onboarding + warn about macOS Optimized Charging / built-in limit (macOS 26.4+) | ❌ | new |

## 3. Shared contracts (all agents must use these exact names)

`Sources/ChargeCapCore/HardwareCommand.swift` (Phase 1, agent A):
```swift
public struct HardwareCommand: Equatable, Sendable {
    public var chargingEnabled: Bool
    public var forceDischarge: Bool
    public var magSafeLED: UInt8?          // nil = don't touch the LED
    public var preventSleep: Bool
    public var preventSleepReason: String
    public init(chargingEnabled: Bool, forceDischarge: Bool, magSafeLED: UInt8?, preventSleep: Bool, preventSleepReason: String = "ChargeCap")
}
public enum PowerSourceScope: String, Codable, Sendable { case all, battery, adapter }
```
`HelperClient` (MainActor, ObservableObject) public surface after Phase 1:
```swift
@Published isHelperConnected: Bool
@Published helperStatusMessage: String
@Published helperNeedsUpdate: Bool          // installed helper version != bundled
@Published installedHelperVersion: String?
@Published detectedKeyFamily: SMCKeyFamily
@Published sleepAssertionActive: Bool
@Published lastAppliedCommand: HardwareCommand?
func checkHelperStatus()
func installOrUpdateHelper()                 // admin-prompt install; replaces installHelper/installHelperWithAdminPrompt
func uninstallHelper()
func apply(_ command: HardwareCommand, force: Bool = false)   // deduped; force re-sends everything
func setClassicMaxCharge(_ value: UInt8)     // Intel BCLM, deduped
func setLowPowerMode(_ enabled: Bool, scope: PowerSourceScope)
func restoreOnQuit(keepChargeInhibited: Bool) // synchronous, ≤1.5 s timeout
func readSMCDiagnostics() -> [(key: String, type: String, hex: String)]  // read-only, for Helper settings page
```

`ChargePolicy` (Phase 2, agent B) — pure, in `ChargeCapCore`, unit-tested:
```swift
public struct PolicyInput { snapshot, limit, sailingEnabled, sailingLowerBound, heatEnabled, heatMaxC,
  autoDischarge, dischargeInClamshell, lidClosed, topUpActive, manualDischargeActive,
  calibrationPhase, calibrationHoldStart, heatPausedSince, useHardwarePercentage, disableSleepUntilLimit,
  ledMode, ledBlinkWhileDischarging, previousMode, now }
public struct PolicyOutput { mode: OperatingMode, command: HardwareCommand, events: [PolicyEvent] }
public enum ChargePolicy { public static func evaluate(_ input: PolicyInput) -> PolicyOutput }
```
(`OperatingMode` and `CalibrationPhase` move into ChargeCapCore.)

## 4. Phases & agent assignments (file ownership is exclusive within a phase)

### Phase 1 (parallel)
**A — Helper & IPC hardening.** Owns: `ChargeCapCore/HelperToolProtocol.swift`, `ChargeCapCore/SMC.swift`,
new `ChargeCapCore/HardwareCommand.swift`, `ChargeCapHelper/main.swift`, `ChargeCap/Controller/HelperClient.swift`,
`Resources/com.chargecap.app.helper.plist`, `Scripts/bundle.sh`. Minimal compile-only touch-ups allowed in
`ChargeController.swift`, `SettingsView.swift`, `PopoverView.swift` where they call removed HelperClient methods.
- XPC client validation with `NSXPCConnection.setCodeSigningRequirement` (team ID read from the helper's own
  signature at runtime; identifier-only requirement when ad-hoc signed). App side validates the helper too.
- Key allowlist for `setSMCBytes`/`readSMCBytes`. All charge/discharge key logic lives only in the helper.
- New helper call `applyState(chargingEnabled:forceDischarge:led:reply:)` doing all writes in one round trip
  (LED byte 0xFF = leave untouched); `setLowPowerMode(enabled:scope:)` running `/usr/bin/pmset -a|-b|-c lowpowermode 0|1`
  with validated args via `Process`; `getVersion`.
- Bump `helperVersion` to `"28.0"`; `helperNeedsUpdate` when mismatched; reconnect logic.
- Install: drop the SMAppService.daemon path (label collision, never worked); admin-script install with proper
  single-quote escaping; remove the bundled LaunchDaemons plist from the bundle.
- `apply` de-dupes against `lastAppliedCommand`; prevent-sleep assertion stays in-process.
- `restoreOnQuit` uses `synchronousRemoteObjectProxyWithErrorHandler` + semaphore timeout.

**D — New standalone services.** Owns new files only, plus `ChargeCapCore/BatteryTelemetry.swift`.
- `ChargeCap/Controller/EnergyMonitor.swift`: samples per-app energy (`proc_pid_rusage` RUSAGE_INFO_V6
  `ri_energy_nj`/`ri_billed_energy`, CPU-time fallback), aggregates by `.app` bundle, thresholds Low/Medium/High,
  include-background toggle, `quit(app)`; `@Published topApps`. Samples only while observed (start/stop API).
- `ChargeCap/Controller/SleepControl.swift`: keep-awake for duration (30 m, 1 h, 2 h, 5 h, ∞) via in-process
  IOPM assertion; auto-release at battery ≤ X% (default 20) or on unplug; `@Published` remaining time.
- `BatteryTelemetry.swift`: add `lidClosed` (IORegistry `AppleClamshellState`), `isLowPowerModeEnabled`
  (`ProcessInfo`), and keep everything else; make `--status` output unchanged in format.

### Phase 2
**B — Policy engine, controller, prefs, history, tests.** Owns `ChargeController.swift`, `Prefs.swift`,
new `ChargeCapCore/ChargePolicy.swift`, new `ChargeCap/Controller/HistoryStore.swift`, `Package.swift`,
new `Tests/ChargeCapCoreTests/*`, `Dev/SelfTest.swift`.
- Pure `ChargePolicy` per contract; controller becomes thin: read snapshot → policy → `HelperClient.apply`.
- Fixes 9–12 above; heat protection min 5 min pause & disabled in calibration; calibration 10% / hold until
  FullyCharged (min 10 min, max 2 h) / optional "skip if macOS calibrated" ; persisted transient state.
- Configurable refresh interval (2–20 s). Re-assert with `force: true` on wake, helper reconnect, every 60 s,
  and when telemetry contradicts the last command.
- Notifications: request authorization on launch (not in dev mode); per-category toggles.
- New prefs: LED blink-during-discharge, LED off during sleep, low power mode policy, refresh interval,
  menu bar extras/right-click action/LPM tint, popover widget order + hidden set, onboarding-complete flag,
  energy threshold + include-background, sleep-control re-enable %, notification categories, schedule catch-up.
- `HistoryStore`: 60 s samples (7 days) + daily health samples (forever) as JSON in Application Support.
- Swift Testing target `ChargeCapCoreTests` covering the policy (≥ 20 cases). SelfTest must stop touching
  hardware (policy-only + snapshot rendering).

### Phase 3 (parallel)
**C1 — Popover.** Owns `PopoverView.swift` (+ new `UI/Popover/*` files). Native Liquid Glass
(`glassEffect`, `GlassEffectContainer`, `.buttonStyle(.glass)`), customizable widget stack (Controls, Power Flow,
Specifications, Graphs w/ Swift Charts from HistoryStore, Energy apps, Low Power Mode, Sleep Control, Helper status),
adaptive height, helper-update banner.
**C2 — Settings, menu bar, app shell, onboarding.** Owns `SettingsView.swift` (+ new `UI/Settings/*`),
`MenuBarIconRenderer.swift`, `ChargeCapApp.swift`, new `UI/OnboardingView.swift`.
Native sidebar Settings with grouped `Form`s; menu bar live-status icon, macOS-style battery, extra readouts,
right-click action, LPM tint; onboarding (helper install + Optimized Battery Charging / built-in limit warning).
**E — Automation.** Owns `Automation/*`. Schedule: LPM on/off, sailing off, stop discharge, custom weekdays,
task history, catch-up for missed runs. Shortcuts & URL scheme: full AlDente action set.

### Phase 4 (Opus)
Build, run unit tests + hardware-free self-test, review diffs, fix, update README to match reality.

### Helper install via SMAppService
The AppleScript admin-password installer was replaced by `SMAppService.daemon(plistName:)`. The daemon uses its own
launchd label and mach service (`com.chargecap.app.daemon`) so it cannot collide with the legacy
`com.chargecap.app.helper` install; the helper binary keeps signing identifier `com.chargecap.app.helper`. The user
approves it once in Login Items (Touch ID). The daemon exposes `removeLegacyHelper` so the app can delete the old
`/Library` install on first connect. The plist is copied to `Contents/Library/LaunchDaemons` by `Scripts/bundle.sh`
before signing.
