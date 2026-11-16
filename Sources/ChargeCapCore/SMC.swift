//
// SMC.swift
// ChargeCapCore (forked from SMCKit / AlDente)
//
// The MIT License
//
// Copyright (c) 2026 ChargeCap Contributors
// Copyright (c) 2020-2021 David Wernhart
// Copyright (c) 2014-2017 beltex <https://beltex.github.io>
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

import Foundation
import IOKit
import os

public typealias FPE2 = (UInt8, UInt8)
public typealias SP78 = (UInt8, UInt8)

public typealias SMCBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

public extension UInt32 {
    init(fromBytes bytes: (UInt8, UInt8, UInt8, UInt8)) {
        let byte0 = UInt32(bytes.0) << 24
        let byte1 = UInt32(bytes.1) << 16
        let byte2 = UInt32(bytes.2) << 8
        let byte3 = UInt32(bytes.3)
        self = byte0 | byte1 | byte2 | byte3
    }

    init(littleEndianBytes bytes: (UInt8, UInt8, UInt8, UInt8)) {
        let byte0 = UInt32(bytes.0)
        let byte1 = UInt32(bytes.1) << 8
        let byte2 = UInt32(bytes.2) << 16
        let byte3 = UInt32(bytes.3) << 24
        self = byte0 | byte1 | byte2 | byte3
    }
}

public extension UInt16 {
    init(littleEndianBytes bytes: (UInt8, UInt8)) {
        self = UInt16(bytes.0) | (UInt16(bytes.1) << 8)
    }
}

public extension Int16 {
    init(littleEndianBytes bytes: (UInt8, UInt8)) {
        let raw = UInt16(bytes.0) | (UInt16(bytes.1) << 8)
        self = Int16(bitPattern: raw)
    }
}

public extension Float {
    init(littleEndianBytes bytes: (UInt8, UInt8, UInt8, UInt8)) {
        let bits = UInt32(littleEndianBytes: bytes)
        self = Float(bitPattern: bits)
    }
}

public extension Bool {
    init(fromByte byte: UInt8) {
        self = byte != 0
    }
}

public extension Int {
    init(fromFPE2 bytes: FPE2) {
        self = (Int(bytes.0) << 6) + (Int(bytes.1) >> 2)
    }

    func toFPE2() -> FPE2 {
        (UInt8(self >> 6), UInt8((self << 2) ^ ((self >> 6) << 8)))
    }
}

public extension Double {
    init(fromSP78 bytes: SP78) {
        let raw = (Int16(bitPattern: (UInt16(bytes.0) << 8) | UInt16(bytes.1)))
        self = Double(raw) / 256.0
    }
}

public extension FourCharCode {
    init(fromString str: String) {
        precondition(str.utf8.count == 4, "SMC key must be 4 ASCII characters")
        self = str.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    init(fromStaticString str: StaticString) {
        precondition(str.utf8CodeUnitCount == 4)
        self = str.withUTF8Buffer { buffer in
            let byte0 = UInt32(buffer[0]) << 24
            let byte1 = UInt32(buffer[1]) << 16
            let byte2 = UInt32(buffer[2]) << 8
            let byte3 = UInt32(buffer[3])
            return byte0 | byte1 | byte2 | byte3
        }
    }

    func toString() -> String {
        String(describing: UnicodeScalar(self >> 24 & 0xff)!) +
        String(describing: UnicodeScalar(self >> 16 & 0xff)!) +
        String(describing: UnicodeScalar(self >> 8  & 0xff)!) +
        String(describing: UnicodeScalar(self       & 0xff)!)
    }
}

public struct SMCParamStruct {
    public enum Selector: UInt8 {
        case kSMCHandleYPCEvent  = 2
        case kSMCReadKey         = 5
        case kSMCWriteKey        = 6
        case kSMCGetKeyFromIndex = 8
        case kSMCGetKeyInfo      = 9
    }

    public enum Result: UInt8 {
        case kSMCSuccess     = 0
        case kSMCError       = 1
        case kSMCKeyNotFound = 132
    }

    public struct SMCVersion {
        public var major: CUnsignedChar = 0
        public var minor: CUnsignedChar = 0
        public var build: CUnsignedChar = 0
        public var reserved: CUnsignedChar = 0
        public var release: CUnsignedShort = 0
    }

    public struct SMCPLimitData {
        public var version: UInt16 = 0
        public var length: UInt16 = 0
        public var cpuPLimit: UInt32 = 0
        public var gpuPLimit: UInt32 = 0
        public var memPLimit: UInt32 = 0
    }

    public struct SMCKeyInfoData {
        public var dataSize: UInt32 = 0
        public var dataType: UInt32 = 0
        public var dataAttributes: UInt8 = 0
    }

    public var key: UInt32 = 0
    public var vers = SMCVersion()
    public var pLimitData = SMCPLimitData()
    public var keyInfo = SMCKeyInfoData()
    public var padding: UInt16 = 0
    public var result: UInt8 = 0
    public var status: UInt8 = 0
    public var data8: UInt8 = 0
    public var data32: UInt32 = 0
    public var bytes: SMCBytes = (
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0
    )

    public init() {}
}

public struct DataTypes {
    public static let FDS    = DataType(type: FourCharCode(fromStaticString: "{fds"), size: 16)
    public static let Flag   = DataType(type: FourCharCode(fromStaticString: "flag"), size: 1)
    public static let FPE2   = DataType(type: FourCharCode(fromStaticString: "fpe2"), size: 2)
    public static let SP78   = DataType(type: FourCharCode(fromStaticString: "sp78"), size: 2)
    public static let UInt8  = DataType(type: FourCharCode(fromStaticString: "ui8 "), size: 1)
    public static let UInt16 = DataType(type: FourCharCode(fromStaticString: "ui16"), size: 2)
    public static let UInt32 = DataType(type: FourCharCode(fromStaticString: "ui32"), size: 4)
    public static let Int16  = DataType(type: FourCharCode(fromStaticString: "si16"), size: 2)
    public static let Float  = DataType(type: FourCharCode(fromStaticString: "flt "), size: 4)
    public static let Hex1   = DataType(type: FourCharCode(fromStaticString: "hex_"), size: 1)
}

public struct SMCKey: Sendable {
    public let code: FourCharCode
    public let info: DataType

    public init(code: FourCharCode, info: DataType) {
        self.code = code
        self.info = info
    }
}

public struct DataType: Equatable, Sendable {
    public let type: FourCharCode
    public let size: IOByteCount

    public init(type: FourCharCode, size: IOByteCount) {
        self.type = type
        self.size = size
    }
}

public struct SMCKit {
    public enum SMCError: Error, CustomStringConvertible {
        case driverNotFound
        case failedToOpen
        case keyNotFound(code: String)
        case notPrivileged
        case unsafeFanSpeed
        case unknown(kIOReturn: kern_return_t, SMCResult: UInt8)

        public var description: String {
            switch self {
            case .driverNotFound:
                return "AppleSMC driver not found"
            case .failedToOpen:
                return "Failed to open AppleSMC connection"
            case .keyNotFound(let code):
                return "SMC key '\(code)' not found"
            case .notPrivileged:
                return "Root privileges required to write SMC key"
            case .unsafeFanSpeed:
                return "Unsafe fan speed requested"
            case .unknown(let kio, let smc):
                return "SMC error (IOReturn: \(kio), SMCResult: \(smc))"
            }
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) fileprivate static var connection: io_connect_t = 0

    public static func open() throws {
        lock.lock()
        defer { lock.unlock() }
        if connection != 0 { return }

        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSMC")
        )
        if service == 0 { throw SMCError.driverNotFound }

        var conn: io_connect_t = 0
        let result = IOServiceOpen(service, mach_task_self_, 0, &conn)
        IOObjectRelease(service)

        if result != kIOReturnSuccess { throw SMCError.failedToOpen }
        connection = conn
    }

    @discardableResult
    public static func close() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard connection != 0 else { return true }
        let result = IOServiceClose(connection)
        connection = 0
        return result == kIOReturnSuccess
    }

    public static func ensureOpen() throws {
        if connection == 0 {
            try open()
        }
    }

    public static func keyInformation(_ key: FourCharCode) throws -> DataType {
        try ensureOpen()
        var inputStruct = SMCParamStruct()
        inputStruct.key = key
        inputStruct.data8 = SMCParamStruct.Selector.kSMCGetKeyInfo.rawValue
        let outputStruct = try callDriver(&inputStruct)
        return DataType(
            type: outputStruct.keyInfo.dataType,
            size: IOByteCount(outputStruct.keyInfo.dataSize)
        )
    }

    public static func keyInformation(_ code: String) throws -> DataType {
        guard code.utf8.count == 4 else { throw SMCError.keyNotFound(code: code) }
        return try keyInformation(FourCharCode(fromString: code))
    }

    public static func keyInformationAtIndex(_ index: Int) throws -> FourCharCode {
        try ensureOpen()
        var inputStruct = SMCParamStruct()
        inputStruct.data8 = SMCParamStruct.Selector.kSMCGetKeyFromIndex.rawValue
        inputStruct.data32 = UInt32(index)
        let outputStruct = try callDriver(&inputStruct)
        return outputStruct.key
    }

    public static func getKey(_ code: String, type: DataType) -> SMCKey {
        SMCKey(code: FourCharCode(fromString: code), info: type)
    }

    public static func isKeyFound(_ code: String) -> Bool {
        guard code.utf8.count == 4 else { return false }
        return (try? keyInformation(FourCharCode(fromString: code))) != nil
    }

    public static func readData(_ key: SMCKey) throws -> SMCBytes {
        try ensureOpen()
        var inputStruct = SMCParamStruct()
        inputStruct.key = key.code
        inputStruct.keyInfo.dataSize = UInt32(key.info.size)
        inputStruct.data8 = SMCParamStruct.Selector.kSMCReadKey.rawValue
        let outputStruct = try callDriver(&inputStruct)
        return outputStruct.bytes
    }

    public static func readBytes(key code: String) throws -> [UInt8] {
        let fcc = FourCharCode(fromString: code)
        let info = try keyInformation(fcc)
        let raw = try readData(SMCKey(code: fcc, info: info))
        return withUnsafeBytes(of: raw) { ptr in
            Array(ptr.prefix(Int(info.size)))
        }
    }

    public static func writeData(_ key: SMCKey, data: SMCBytes) throws {
        try ensureOpen()
        var inputStruct = SMCParamStruct()
        inputStruct.key = key.code
        inputStruct.bytes = data
        inputStruct.keyInfo.dataSize = UInt32(key.info.size)
        inputStruct.data8 = SMCParamStruct.Selector.kSMCWriteKey.rawValue
        _ = try callDriver(&inputStruct)
    }

    public static func writeBytes(key code: String, bytes: [UInt8]) throws {
        let fcc = FourCharCode(fromString: code)
        let info = try keyInformation(fcc)
        var tuple: SMCBytes = (
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0
        )
        withUnsafeMutableBytes(of: &tuple) { buffer in
            for (idx, byte) in bytes.prefix(32).enumerated() {
                buffer[idx] = byte
            }
        }
        try writeData(SMCKey(code: fcc, info: info), data: tuple)
    }

    public static func readUInt8(_ code: String) -> UInt8? {
        guard let bytes = try? readBytes(key: code), let first = bytes.first else { return nil }
        return first
    }

    public static func readUInt16(_ code: String) -> UInt16? {
        guard let bytes = try? readBytes(key: code), bytes.count >= 2 else { return nil }
        return UInt16(littleEndianBytes: (bytes[0], bytes[1]))
    }

    public static func readInt16(_ code: String) -> Int16? {
        guard let bytes = try? readBytes(key: code), bytes.count >= 2 else { return nil }
        return Int16(littleEndianBytes: (bytes[0], bytes[1]))
    }

    public static func readUInt32(_ code: String) -> UInt32? {
        guard let bytes = try? readBytes(key: code), bytes.count >= 4 else { return nil }
        return UInt32(littleEndianBytes: (bytes[0], bytes[1], bytes[2], bytes[3]))
    }

    public static func readTemperatureCelsius(_ code: String) -> Double? {
        guard code.utf8.count == 4 else { return nil }
        let fcc = FourCharCode(fromString: code)
        guard let info = try? keyInformation(fcc),
              let raw = try? readData(SMCKey(code: fcc, info: info)) else {
            return nil
        }
        let typeStr = info.type.toString()
        if typeStr == "flt " {
            let value = Double(Float(littleEndianBytes: (raw.0, raw.1, raw.2, raw.3)))
            return (value > 0 && value < 125) ? value : nil
        } else if typeStr == "sp78" {
            let value = Double(fromSP78: (raw.0, raw.1))
            return (value > 0 && value < 125) ? value : nil
        } else if typeStr == "ui16" {
            // Gas gauge temperature in 0.1 Kelvin (e.g. B0AT = 3116 -> 38.45 C)
            let deciKelvin = Double(UInt16(littleEndianBytes: (raw.0, raw.1)))
            let celsius = (deciKelvin / 10.0) - 273.15
            return (celsius > 0 && celsius < 125) ? celsius : nil
        }
        return nil
    }

    public static func callDriver(
        _ inputStruct: inout SMCParamStruct,
        selector: SMCParamStruct.Selector = .kSMCHandleYPCEvent
    ) throws -> SMCParamStruct {
        lock.lock()
        defer { lock.unlock() }
        assert(MemoryLayout<SMCParamStruct>.stride == 80, "SMCParamStruct size is != 80")

        var outputStruct = SMCParamStruct()
        let inputStructSize = MemoryLayout<SMCParamStruct>.stride
        var outputStructSize = MemoryLayout<SMCParamStruct>.stride

        let result = IOConnectCallStructMethod(
            connection,
            UInt32(selector.rawValue),
            &inputStruct,
            inputStructSize,
            &outputStruct,
            &outputStructSize
        )

        switch (result, outputStruct.result) {
        case (kIOReturnSuccess, SMCParamStruct.Result.kSMCSuccess.rawValue):
            return outputStruct
        case (kIOReturnSuccess, SMCParamStruct.Result.kSMCKeyNotFound.rawValue):
            throw SMCError.keyNotFound(code: inputStruct.key.toString())
        case (kIOReturnNotPrivileged, _):
            throw SMCError.notPrivileged
        default:
            throw SMCError.unknown(kIOReturn: result, SMCResult: outputStruct.result)
        }
    }
}
