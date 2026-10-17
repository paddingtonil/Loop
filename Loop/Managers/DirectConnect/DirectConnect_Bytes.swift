//
//  DirectConnect_Bytes.swift
//  Loop (AID) PowerPack — based on LoopKit/Loop.
//  DirectConnect — Little-endian readers, hex, CRC and chunking helpers.
//  Idea by Taylor Patterson. Coded by Claude Code.
//  Portions derived from xDrip4iOS (https://github.com/JohanDegraeve/xdripswift), GPL-3.0.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.

import Foundation

// Every helper carries a `dc` prefix: the Loop target already links several modules that
// extend `Data` with similarly named members, and an unprefixed name would be ambiguous.
extension Data {
    func dcUInt16LE(at offset: Int) -> UInt16 {
        let i = startIndex + offset
        return UInt16(self[i]) | UInt16(self[i + 1]) << 8
    }

    func dcUInt24LE(at offset: Int) -> UInt32 {
        let i = startIndex + offset
        return UInt32(self[i]) | UInt32(self[i + 1]) << 8 | UInt32(self[i + 2]) << 16
    }

    func dcUInt32LE(at offset: Int) -> UInt32 {
        let i = startIndex + offset
        return UInt32(self[i])
            | UInt32(self[i + 1]) << 8
            | UInt32(self[i + 2]) << 16
            | UInt32(self[i + 3]) << 24
    }

    func dcByte(at offset: Int) -> UInt8 {
        self[startIndex + offset]
    }

    var dcHex: String {
        map { String(format: "%02x", $0) }.joined()
    }

    init?(dcHex hex: String) {
        guard hex.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }

    /// CRC-16/XMODEM (CCITT polynomial 0x1021, initial value 0), as used by Dexcom commands.
    var dcCRC16: UInt16 {
        var crc: UInt16 = 0
        for byte in self {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1
            }
        }
        return crc
    }

    /// Appends the CRC little-endian, matching the Dexcom wire format.
    func dcAppendingCRC() -> Data {
        let crc = dcCRC16
        return self + Data([UInt8(crc & 0xFF), UInt8(crc >> 8)])
    }

    func dcChunked(into size: Int) -> [Data] {
        guard size > 0, !isEmpty else { return [] }
        return stride(from: 0, to: count, by: size).map { offset in
            let start = startIndex + offset
            return Data(self[start..<Swift.min(start + size, endIndex)])
        }
    }

    static func dcUInt32LEBytes(_ value: UInt32) -> Data {
        Data([UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8(value >> 24)])
    }

    static func dcUInt16LEBytes(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xFF), UInt8(value >> 8)])
    }
}
