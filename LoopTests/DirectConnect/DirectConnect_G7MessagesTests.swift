//
//  DirectConnect_G7MessagesTests.swift
//  LoopTests
//
//  Concept & design by Taylor Patterson. Coded & tested by Claude Code in October 2026.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.
//

import XCTest
import LoopKit
@testable import Loop

final class DirectConnect_G7MessagesTests: XCTestCase {
    func testGlucoseMessageParsesG7SensorKitVector() {
        let m = DirectConnect_G7GlucoseMessage(data: Data(dcHex: "4e00d507000009000001050061000601ffff0e")!)!
        XCTAssertEqual(m.responseStatus, 0)
        XCTAssertEqual(m.messageTimestamp, 2005)
        XCTAssertEqual(m.sequence, 9)
        XCTAssertEqual(m.age, 5)
        XCTAssertEqual(m.glucoseTimestamp, 2000)
        XCTAssertEqual(m.glucose, 97)
        XCTAssertEqual(m.algorithmState, .known(.ok))
        XCTAssertEqual(m.trend, 0.1)
        XCTAssertNil(m.predicted)
        XCTAssertTrue(m.hasReliableGlucose)
    }

    func testGlucoseMessageKeepsNonZeroResponseStatus() {
        let m = DirectConnect_G7GlucoseMessage(data: Data(dcHex: "4e01d507000009000001050061000601ffff0e")!)!
        XCTAssertEqual(m.responseStatus, 1)
    }

    func testCapturedFailedSensorFrameKeepsStatusAndCachedValue() {
        // Captured by xDrip4iOS from a failed sensor: non-zero status with a stale cached value.
        let m = DirectConnect_G7GlucoseMessage(data: Data(dcHex: "4e80a26b0200e8010001793990001b04ab0000")!)!
        XCTAssertEqual(m.responseStatus, 0x80)
        XCTAssertEqual(m.messageTimestamp, 158_626)
        XCTAssertEqual(m.age, 14_713)
        XCTAssertEqual(m.glucose, 144)
        XCTAssertFalse(m.hasReliableGlucose)
    }

    func testCapturedBatteryFrame() {
        let m = DirectConnect_G7BatteryStatus(data: Data(dcHex: "220020010b0106210000000001")!)!
        XCTAssertEqual(m.status, 0)
        XCTAssertEqual(m.voltageA, 288)
        XCTAssertEqual(m.voltageB, 267)
        XCTAssertEqual(m.resistance, 8_454)
        XCTAssertEqual(m.runtime, 0)
        XCTAssertEqual(m.temperature, 0)
    }

    func testGlucoseMessageRejectsShortOrWrongOpcode() {
        XCTAssertNil(DirectConnect_G7GlucoseMessage(data: Data([0x4E, 0x00])))
        XCTAssertNil(DirectConnect_G7GlucoseMessage(data: Data(dcHex: "31000000000000000000000000000000000000")!))
    }

    func testBackfillVector() {
        let m = DirectConnect_G7BackfillMessage(data: Data(dcHex: "45a100009600060ffc")!)!
        XCTAssertEqual(m.timestamp, 0x00a145)
        XCTAssertEqual(m.glucose, 150)
        XCTAssertEqual(m.algorithmState, .known(.ok))
        XCTAssertEqual(m.trend, -0.4)
    }

    func testExtendedVersionTenAndFifteenDay() {
        let ten = DirectConnect_G7ExtendedVersion(data: Data(dcHex: "5200c0d70d00540600020404ff0c00")!)!
        XCTAssertEqual(ten.sessionLength, 907200)
        XCTAssertEqual(ten.warmupDuration, 1620)
        XCTAssertEqual(ten.maxLifetimeDays, 12)
        let fifteen = DirectConnect_G7ExtendedVersion(data: Data(dcHex: "5200406f1400880e00010a04ff1100")!)!
        XCTAssertEqual(fifteen.sessionLength, 1339200)
        XCTAssertEqual(fifteen.warmupDuration, 3720)
        XCTAssertEqual(fifteen.maxLifetimeDays, 17)
    }

    func testBatteryStatus() {
        let m = DirectConnect_G7BatteryStatus(data: Data(dcHex: "2200100e0a0eb40014f6")!)!
        XCTAssertEqual(m.voltageA, 0x0e10); XCTAssertEqual(m.voltageB, 0x0e0a)
        XCTAssertEqual(m.resistance, 180); XCTAssertEqual(m.runtime, 20); XCTAssertEqual(m.temperature, -10)
    }

    func testVersionInfo() {
        let m = DirectConnect_G7VersionInfo(data: Data(dcHex: "4a00020301040a00000014000000010203040506")!)!
        XCTAssertEqual(m.firmwareVersion, "2.3.1.4")
        XCTAssertEqual(m.buildVersion, 10); XCTAssertEqual(m.versionCode, 20)
        XCTAssertEqual(m.serialNumber, 0x060504030201)
    }

    func testAuthMessages() {
        let req = DirectConnect_AuthRequestRx(data: Data(dcHex: "030102030405060708a1a2a3a4a5a6a7a8")!)!
        XCTAssertEqual(req.tokenHash, Data(dcHex: "0102030405060708"))
        XCTAssertEqual(req.challenge, Data(dcHex: "a1a2a3a4a5a6a7a8"))
        let ok = DirectConnect_AuthStatusRx(data: Data([0x05, 0x01, 0x01]))!
        XCTAssertTrue(ok.authenticated); XCTAssertTrue(ok.paired)
        let unpaired = DirectConnect_AuthStatusRx(data: Data([0x05, 0x01, 0x02]))!
        XCTAssertTrue(unpaired.authenticated); XCTAssertFalse(unpaired.paired)
    }

    func testCRCRequests() {
        XCTAssertEqual(Data([0x22]).dcCRC16, Data([0x22]).dcAppendingCRC().dcUInt16LE(at: 1))
        XCTAssertEqual(DirectConnect_G7Requests.battery.count, 3)
        XCTAssertEqual(DirectConnect_G7Requests.version.first, 0x4A)
    }

    func testCRCMatchesXModemCheckValue() {
        // CRC-16/XMODEM check value for ASCII "123456789" is 0x31C3.
        XCTAssertEqual(Data("123456789".utf8).dcCRC16, 0x31C3)
    }

    func testChunking() {
        let chunks = Data(repeating: 1, count: 45).dcChunked(into: 20)
        XCTAssertEqual(chunks.map(\.count), [20, 20, 5])
    }

    func testHexRoundTrip() {
        XCTAssertEqual(Data(dcHex: "00ff10")?.dcHex, "00ff10")
        XCTAssertNil(Data(dcHex: "0g"))
        XCTAssertNil(Data(dcHex: "123"))
    }
}
