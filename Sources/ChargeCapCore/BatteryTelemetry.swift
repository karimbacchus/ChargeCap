//
// BatteryTelemetry.swift
// ChargeCapCore
//
// MIT License
//

import Foundation
import IOKit
import IOKit.ps

public struct BatterySnapshot: Sendable, Equatable, Codable {
    public var timestamp: Date
    public var osPercentage: Int
    public var hardwarePercentage: Double
    public var isCharging: Bool
    public var isPluggedIn: Bool
    public var isFullyCharged: Bool
    public var chargeInhibitedBySMC: Bool
    public var forceDischargingBySMC: Bool
    public var magSafeLEDByte: UInt8

    // Capacity & Health (mAh)
    public var currentCapacityMah: Int
    public var fullChargeCapacityMah: Int
    public var nominalCapacityMah: Int
    public var designCapacityMah: Int
    public var cycleCount: Int
    public var healthPercentage: Double

    // Electrical & Power Flow (V, A, W)
    public var voltageVolts: Double
    public var amperageAmps: Double
    public var batteryPowerWatts: Double      // Positive = charging battery, Negative = discharging battery
    public var adapterInputWatts: Double      // Total power coming from wall adapter
    public var systemLoadWatts: Double        // Power consumed by Mac system
    public var usbExternalOutWatts: Double    // Power supplied to connected USB-C accessories
    public var adapterEfficiencyLossWatts: Double
    public var cellVoltagesMillivolts: [Int]  // Individual cell voltages (Cell 1, Cell 2, Cell 3)

    // Thermal (Celsius)
    public var batteryTemperatureC: Double
    public var sensorTemperaturesC: [Double]
    public var minLifetimeTemperatureC: Double?
    public var maxLifetimeTemperatureC: Double?

    // Charger Details
    public var adapterName: String
    public var adapterManufacturer: String
    public var adapterRatedWatts: Int
    public var adapterNegotiatedVolts: Double
    public var adapterNegotiatedAmps: Double
    public var timeRemainingMinutes: Int?

    public var effectivePercentage: Int {
        osPercentage
    }

    public func percentage(useHardware: Bool) -> Double {
        useHardware ? hardwarePercentage : Double(osPercentage)
    }

    public var cellDeltaMillivolts: Int {
        guard let minV = cellVoltagesMillivolts.min(),
              let maxV = cellVoltagesMillivolts.max() else { return 0 }
        return maxV - minV
    }

    public static let placeholder = BatterySnapshot(
        timestamp: Date(),
        osPercentage: 80,
        hardwarePercentage: 79.6,
        isCharging: false,
        isPluggedIn: true,
        isFullyCharged: false,
        chargeInhibitedBySMC: true,
        forceDischargingBySMC: false,
        magSafeLEDByte: 3,
        currentCapacityMah: 7100,
        fullChargeCapacityMah: 8882,
        nominalCapacityMah: 8936,
        designCapacityMah: 8532,
        cycleCount: 11,
        healthPercentage: 100.0,
        voltageVolts: 13.35,
        amperageAmps: 0.0,
        batteryPowerWatts: 0.0,
        adapterInputWatts: 23.1,
        systemLoadWatts: 22.6,
        usbExternalOutWatts: 0.1,
        adapterEfficiencyLossWatts: 0.5,
        cellVoltagesMillivolts: [4451, 4454, 4446],
        batteryTemperatureC: 32.4,
        sensorTemperaturesC: [32.4, 32.4, 31.8],
        minLifetimeTemperatureC: 14.8,
        maxLifetimeTemperatureC: 45.1,
        adapterName: "140W USB-C Power Adapter",
        adapterManufacturer: "Apple Inc.",
        adapterRatedWatts: 140,
        adapterNegotiatedVolts: 20.0,
        adapterNegotiatedAmps: 4.7,
        timeRemainingMinutes: nil
    )
}

public enum BatteryTelemetryReader {
    public static func readSnapshot() -> BatterySnapshot {
        var osPercentage = 100
        var isCharging = false
        var isPluggedIn = false
        var isFullyCharged = false
        var timeRemainingMinutes: Int? = nil

        // 1. Read standard IOPS power source info
        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef],
           let first = sources.first,
           let desc = IOPSGetPowerSourceDescription(blob, first)?.takeUnretainedValue() as? [String: Any] {
            if let cap = desc[kIOPSCurrentCapacityKey as String] as? Int {
                osPercentage = cap
            }
            if let charging = desc[kIOPSIsChargingKey as String] as? Bool {
                isCharging = charging
            }
            if let powerState = desc[kIOPSPowerSourceStateKey as String] as? String {
                isPluggedIn = (powerState == (kIOPSACPowerValue as String))
            }
            if let charged = desc[kIOPSIsChargedKey as String] as? Bool {
                isFullyCharged = charged
            }
            if isCharging, let ttf = desc[kIOPSTimeToFullChargeKey as String] as? Int, ttf > 0 && ttf < 6000 {
                timeRemainingMinutes = ttf
            } else if !isPluggedIn, let tte = desc[kIOPSTimeToEmptyKey as String] as? Int, tte > 0 && tte < 6000 {
                timeRemainingMinutes = tte
            }
        }

        // 2. Read detailed AppleSmartBattery & AppleSmartBatteryPack IORegistry properties
        var currentMah = Int(SMCKit.readUInt16("B0RM") ?? 0)
        var fullMah = Int(SMCKit.readUInt16("B0FC") ?? 0)
        var nominalMah = fullMah
        var designMah = Int(SMCKit.readUInt16("B0DC") ?? 0)
        var cycleCount = Int(SMCKit.readUInt16("B0CT") ?? 0)
        var voltageMv = Int(SMCKit.readUInt16("B0AV") ?? 12000)
        var amperageMa = Int(SMCKit.readInt16("B0AC") ?? 0)

        var adapterInputWatts: Double = 0
        var systemLoadWatts: Double = 0
        var usbExternalOutWatts: Double = 0
        var adapterLossWatts: Double = 0
        var adapterName = "Power Adapter"
        var adapterManufacturer = "Apple Inc."
        var adapterRatedWatts = 0
        var adapterVolts: Double = 0
        var adapterAmps: Double = 0
        var minLifetimeTempC: Double? = nil
        var maxLifetimeTempC: Double? = nil
        var ioRegTempC: Double? = nil

        let smartBat = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if smartBat != 0 {
            defer { IOObjectRelease(smartBat) }
            var unmanagedProps: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(smartBat, &unmanagedProps, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = unmanagedProps?.takeRetainedValue() as? [String: Any] {

                if let ext = dict["ExternalConnected"] as? Bool { isPluggedIn = ext }
                if let chg = dict["IsCharging"] as? Bool { isCharging = chg }
                if let full = dict["FullyCharged"] as? Bool { isFullyCharged = full }
                if let cc = dict["CycleCount"] as? Int { cycleCount = cc }
                if let v = dict["Voltage"] as? Int { voltageMv = v }
                if let a = dict["Amperage"] as? Int { amperageMa = a }
                if let rawCur = dict["AppleRawCurrentCapacity"] as? Int { currentMah = rawCur }
                if let rawMax = dict["AppleRawMaxCapacity"] as? Int { fullMah = rawMax }
                if let des = dict["DesignCapacity"] as? Int { designMah = des }
                if let nom = dict["NominalChargeCapacity"] as? Int { nominalMah = nom }

                if let batData = dict["BatteryData"] as? [String: Any] {
                    if let rawCur = batData["AppleRawCurrentCapacity"] as? Int { currentMah = rawCur }
                    if let rawMax = batData["AppleRawMaxCapacity"] as? Int { fullMah = rawMax }
                    if let des = batData["DesignCapacity"] as? Int { designMah = des }
                    if let nom = batData["NominalChargeCapacity"] as? Int { nominalMah = nom }
                }

                if let telemetry = dict["PowerTelemetryData"] as? [String: Any] {
                    if let sysInMw = telemetry["SystemPowerIn"] as? Int {
                        adapterInputWatts = Double(sysInMw) / 1000.0
                    }
                    if let sysLoadMw = telemetry["SystemLoad"] as? Int {
                        systemLoadWatts = Double(sysLoadMw) / 1000.0
                    }
                    if let lossMw = telemetry["AdapterEfficiencyLoss"] as? Int {
                        adapterLossWatts = Double(lossMw) / 1000.0
                    }
                }

                if let powerDist = dict["PowerDistribution"] as? [String: Any], adapterInputWatts == 0 {
                    if let inPowerMw = powerDist["IPDInputPower"] as? Int, isPluggedIn {
                        adapterInputWatts = min(Double(inPowerMw) / 1000.0, 240.0)
                    }
                }

                if let adapter = dict["AdapterDetails"] as? [String: Any] {
                    if let name = adapter["Name"] as? String, !name.isEmpty {
                        adapterName = name
                    } else if let desc = adapter["Description"] as? String, !desc.isEmpty {
                        adapterName = desc.uppercased()
                    }
                    if let mfg = adapter["Manufacturer"] as? String, !mfg.isEmpty {
                        adapterManufacturer = mfg
                    }
                    if let watts = adapter["Watts"] as? Int {
                        adapterRatedWatts = watts
                    }
                    if let mv = adapter["AdapterVoltage"] as? Int {
                        adapterVolts = Double(mv) / 1000.0
                    }
                    if let ma = adapter["Current"] as? Int {
                        adapterAmps = Double(ma) / 1000.0
                    }
                }

                if let powerOut = dict["PowerOutDetails"] as? [[String: Any]] {
                    var totalOutMw = 0
                    for port in powerOut {
                        if let p = port["FilteredPower"] as? Int {
                            totalOutMw += p
                        }
                    }
                    usbExternalOutWatts = Double(totalOutMw) / 1000.0
                }
            }
        }

        let packService = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBatteryPack"))
        if packService != 0 {
            defer { IOObjectRelease(packService) }
            var unmanagedProps: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(packService, &unmanagedProps, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = unmanagedProps?.takeRetainedValue() as? [String: Any],
               let batData = dict["BatteryData"] as? [String: Any] {
                if let tempRaw = batData["Temperature"] as? Int {
                    // On AppleSmartBatteryPack, Temperature is either centi-Celsius (e.g. 3850 -> 38.50 C) or deci-Kelvin
                    let candidateC = Double(tempRaw) / 100.0
                    if candidateC > 5 && candidateC < 100 {
                        ioRegTempC = candidateC
                    } else {
                        let kelvinC = (Double(tempRaw) / 10.0) - 273.15
                        if kelvinC > 5 && kelvinC < 100 { ioRegTempC = kelvinC }
                    }
                }
                if let lifetime = batData["LifetimeData"] as? [String: Any] {
                    if let minT = lifetime["MinimumTemperature"] as? Int {
                        let c = (Double(minT) / 10.0) - 273.15
                        if c > -30 && c < 80 { minLifetimeTempC = c }
                    }
                    if let maxT = lifetime["MaximumTemperature"] as? Int {
                        let c = (Double(maxT) / 10.0) - 273.15
                        if c > 0 && c < 100 { maxLifetimeTempC = c }
                    }
                }
            }
        }

        // 3. Read SMC temperatures & cell voltages
        let sensorKeys = ["TB0T", "TB1T", "TB2T"]
        var sensorsC: [Double] = []
        for key in sensorKeys {
            if let t = SMCKit.readTemperatureCelsius(key) {
                sensorsC.append(t)
            }
        }
        if sensorsC.isEmpty, let b0at = SMCKit.readTemperatureCelsius("B0AT") {
            sensorsC.append(b0at)
        }
        let primaryTempC = sensorsC.max() ?? ioRegTempC ?? 30.0

        var cellVoltages: [Int] = []
        for cellKey in ["BC1V", "BC2V", "BC3V"] {
            if let mv = SMCKit.readUInt16(cellKey), mv > 2000 && mv < 5500 {
                cellVoltages.append(Int(mv))
            }
        }

        // 4. Read SMC Charge / Discharge / MagSafe states
        let chib = SMCKit.readUInt8("CHIB") ?? 0
        let ch0b = SMCKit.readUInt8("CH0B") ?? 0
        let chte = SMCKit.readUInt32("CHTE") ?? 0
        let chce = SMCKit.readUInt8("CHCE") ?? 1
        let chie = SMCKit.readUInt8("CHIE") ?? 0
        let ch0i = SMCKit.readUInt8("CH0I") ?? 0
        let aclc = SMCKit.readUInt8("ACLC") ?? 0

        let chargeInhibited = (chib != 0) || (ch0b != 0) || (chte != 0) || (chce == 0)
        let forceDischarging = (chie != 0) || (ch0i != 0)

        // 5. Compute derived metrics
        let voltageV = Double(voltageMv) / 1000.0
        let amperageA = Double(amperageMa) / 1000.0
        let batteryWatts = voltageV * amperageA
        if systemLoadWatts == 0 {
            if isPluggedIn && adapterInputWatts > 0 {
                systemLoadWatts = max(0, adapterInputWatts - max(0, batteryWatts))
            } else {
                systemLoadWatts = abs(batteryWatts)
            }
        }
        if !isPluggedIn || forceDischarging {
            adapterInputWatts = 0
        }

        let hwPercent: Double
        if fullMah > 0 && currentMah > 0 {
            hwPercent = min(100.0, max(0.0, (Double(currentMah) / Double(fullMah)) * 100.0))
        } else {
            hwPercent = Double(osPercentage)
        }

        let healthPercent: Double
        if designMah > 0 && fullMah > 0 {
            healthPercent = min(110.0, max(10.0, (Double(fullMah) / Double(designMah)) * 100.0))
        } else {
            healthPercent = 100.0
        }

        return BatterySnapshot(
            timestamp: Date(),
            osPercentage: osPercentage,
            hardwarePercentage: hwPercent,
            isCharging: isCharging,
            isPluggedIn: isPluggedIn,
            isFullyCharged: isFullyCharged,
            chargeInhibitedBySMC: chargeInhibited,
            forceDischargingBySMC: forceDischarging,
            magSafeLEDByte: aclc,
            currentCapacityMah: currentMah,
            fullChargeCapacityMah: fullMah,
            nominalCapacityMah: nominalMah,
            designCapacityMah: designMah,
            cycleCount: cycleCount,
            healthPercentage: healthPercent,
            voltageVolts: voltageV,
            amperageAmps: amperageA,
            batteryPowerWatts: batteryWatts,
            adapterInputWatts: adapterInputWatts,
            systemLoadWatts: systemLoadWatts,
            usbExternalOutWatts: usbExternalOutWatts,
            adapterEfficiencyLossWatts: adapterLossWatts,
            cellVoltagesMillivolts: cellVoltages,
            batteryTemperatureC: primaryTempC,
            sensorTemperaturesC: sensorsC,
            minLifetimeTemperatureC: minLifetimeTempC,
            maxLifetimeTemperatureC: maxLifetimeTempC,
            adapterName: adapterName,
            adapterManufacturer: adapterManufacturer,
            adapterRatedWatts: adapterRatedWatts,
            adapterNegotiatedVolts: adapterVolts,
            adapterNegotiatedAmps: adapterAmps,
            timeRemainingMinutes: timeRemainingMinutes
        )
    }
}
