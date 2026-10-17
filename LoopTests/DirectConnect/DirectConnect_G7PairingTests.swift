//
//  DirectConnect_G7PairingTests.swift
//  LoopTests
//
//  Concept & design by Taylor Patterson. Coded & tested by Claude Code in October 2026.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.
//

import XCTest
@testable import Loop

final class DirectConnect_G7PairingTests: XCTestCase {
    private let key = Data(repeating: 0x42, count: 16)
    private let token = Data(dcHex: "0102030405060708")!

    private func controlWrites(_ events: [DirectConnect_PairingEvent]) -> [Data] {
        events.flatMap { event -> [Data] in
            if case let .writes(w) = event { return w.filter { $0.target == .control }.map(\.data) }
            return []
        }
    }

    private func streamWrites(_ events: [DirectConnect_PairingEvent]) -> [DirectConnect_AuthWrite] {
        events.flatMap { event -> [DirectConnect_AuthWrite] in
            if case let .writes(w) = event { return w.filter { $0.target == .stream } }
            return []
        }
    }

    private func pairing(savedKey: Bool, code: String? = nil) -> (DirectConnect_G7Pairing, DirectConnect_MemoryKeyStore) {
        let store = DirectConnect_MemoryKeyStore()
        if savedKey { store.save(key, sensor: "DXCMab", slot: 2) }
        return (DirectConnect_G7Pairing(sensorName: "DXCMab", pairingCode: code, keyStore: store, tokenSource: { self.token }), store)
    }

    func testSavedKeyStartsShortAuth() {
        let (p, _) = pairing(savedKey: true)
        XCTAssertEqual(p.start(), .writes([DirectConnect_AuthWrite(target: .control, data: Data([0x02]) + token + Data([0x02]), delay: 0)]))
    }

    func testShortAuthChallengeResponseThenAuthenticated() throws {
        let (p, _) = pairing(savedKey: true)
        _ = p.start()
        let challenge = Data(dcHex: "a1a2a3a4a5a6a7a8")!
        let tokenHash = try DirectConnect_G7Crypto.challengeHash(token, key: key)
        let events = p.receiveControl(Data([0x03]) + tokenHash + challenge)
        XCTAssertEqual(controlWrites(events), [Data([0x04]) + (try DirectConnect_G7Crypto.challengeHash(challenge, key: key))])
        XCTAssertEqual(p.receiveControl(Data([0x05, 0x01, 0x01])), [.authenticated])
    }

    func testDuplicateChallengeIsAnsweredOnce() throws {
        let (p, _) = pairing(savedKey: true)
        _ = p.start()
        let packet = Data([0x03]) + Data(repeating: 0, count: 8) + Data(dcHex: "a1a2a3a4a5a6a7a8")!
        XCTAssertEqual(controlWrites(p.receiveControl(packet)).count, 1)
        XCTAssertEqual(controlWrites(p.receiveControl(packet)).count, 0)
    }

    func testRejectedSavedKeyStopsWithoutClearingKey() {
        let (p, store) = pairing(savedKey: true)
        _ = p.start()
        XCTAssertEqual(p.receiveControl(Data([0x05, 0x00, 0x02])), [.rejectedSavedKey])
        XCTAssertEqual(store.key(sensor: "DXCMab", slot: 2), key)
    }

    func testAuthenticatedButUnpairedClearsKeyAndReconnects() {
        let (p, store) = pairing(savedKey: true)
        _ = p.start()
        XCTAssertEqual(p.receiveControl(Data([0x05, 0x01, 0x02])), [.needsCleanReconnect])
        XCTAssertNil(store.key(sensor: "DXCMab", slot: 2))
    }

    func testForceFullPairingIgnoresSavedKey() {
        let (p, _) = pairing(savedKey: true, code: "1234")
        p.forceFullPairing = true
        XCTAssertEqual(p.start(), .writes([DirectConnect_AuthWrite(target: .control, data: Data([0x0A, 0x00]), delay: 0)]))
    }

    func testNoSavedKeyStartsJPAKE() {
        let (p, _) = pairing(savedKey: false, code: "1234")
        XCTAssertEqual(p.start(), .writes([DirectConnect_AuthWrite(target: .control, data: Data([0x0A, 0x00]), delay: 0)]))
    }

    func testNoSavedKeyAndNoCodeFails() {
        let (p, _) = pairing(savedKey: false)
        guard case .failed = p.start() else { return XCTFail("expected failure") }
    }

    func testPakeRefusalIsNotACodeRejectionAndDoesNotPersistKey() {
        // The sensor refuses before it has received anything derived from the code, so the
        // refusal says nothing about the code. A new G7 did this twice on 2026-10-16 with the
        // correct code, and treating it as a wrong code made Loop skip that sensor.
        let (p, store) = pairing(savedKey: false, code: "1234")
        _ = p.start()
        XCTAssertEqual(p.receiveControl(Data([0x0A, 0x01, 0x00])), [.pakeRefused])
        XCTAssertNil(store.key(sensor: "DXCMab", slot: 2))
    }

    func testCertificateRefusalIsReportedSeparately() {
        // Reached only after the sensor accepted the code-derived key.
        let (p, store) = pairing(savedKey: false, code: "1234")
        p.testHook_setCandidateKey(key, stage: .certificateExchange, fullBootstrap: true)
        XCTAssertEqual(p.receiveControl(Data([0x0B, 0x01, 0x00, 0, 0, 0, 0])), [.certificateRefused])
        XCTAssertNil(store.key(sensor: "DXCMab", slot: 2))
    }

    func testCertificateMessageOutsideTheExchangeStillFails() {
        let (p, _) = pairing(savedKey: false, code: "1234")
        p.testHook_setCandidateKey(key, stage: .authenticating, fullBootstrap: true)
        guard case .failed = p.receiveControl(Data([0x0B, 0x00, 0x00, 0, 0, 0, 0])).first else { return XCTFail() }
    }

    func testFullBootstrapAuthRejectionReportsCodeRejected() {
        let (p, store) = pairing(savedKey: false, code: "1234")
        p.testHook_setCandidateKey(key, stage: .authenticating, fullBootstrap: true)
        XCTAssertEqual(p.receiveControl(Data([0x05, 0x00, 0x02])), [.codeRejected])
        XCTAssertNil(store.key(sensor: "DXCMab", slot: 2))
    }

    func testPakeStreamAndControlCanArriveInEitherOrder() {
        let (p, _) = pairing(savedKey: false, code: "1234")
        _ = p.start()
        // Off-curve payload: the phase is processed exactly once, after both halves arrive.
        XCTAssertTrue(p.receiveStream(Data(repeating: 0x01, count: 100)).isEmpty)
        XCTAssertTrue(p.receiveStream(Data(repeating: 0x01, count: 60)).isEmpty)
        let events = p.receiveControl(Data([0x0A, 0x00, 0x00]))
        XCTAssertEqual(events.count, 1)
        guard case .failed = events[0] else { return XCTFail("expected validation failure") }
    }

    func testPakePhaseRepliesWithStreamThenControl() throws {
        let (p, _) = pairing(savedKey: false, code: "1234")
        _ = p.start()
        let server = try DirectConnect_G7Crypto.generateKeyPair()
        let packet = try DirectConnect_G7Crypto.makeZKPacket(privateKey: server.privateKey, publicKey: server.publicKey, base: nil, party: DirectConnect_G7Crypto.serverParty)
        _ = p.receiveControl(Data([0x0A, 0x00, 0x00]))
        let events = p.receiveStream(packet)
        let stream = streamWrites(events)
        XCTAssertEqual(stream.map(\.data.count), [20, 20, 20, 20, 20, 20, 20, 20])
        XCTAssertEqual(stream.map(\.delay), (0..<8).map { 0.04 * Double($0) })
        XCTAssertEqual(controlWrites(events), [Data([0x0A, 0x01])])
        guard case let .writes(all) = events[0] else { return XCTFail() }
        XCTAssertEqual(all.last?.target, .control)
        XCTAssertEqual(all.last?.delay ?? 0, 0.04 * 9, accuracy: 0.0001)
    }

    func testOwnershipKeepAliveClassification() {
        XCTAssertEqual(DirectConnect_G7Pairing.keepAliveAction(Data([0x06, 0x01])), .completeOwnership)
        XCTAssertEqual(DirectConnect_G7Pairing.keepAliveAction(Data([0x06, 0x00])), .requestLegacyBond)
        XCTAssertEqual(DirectConnect_G7Pairing.keepAliveAction(Data([0x06, 0x05])), .ignore)
    }

    func testDerivedKeyNotPersistedUntilOwnershipConfirmed() {
        let (p, store) = pairing(savedKey: false, code: "1234")
        p.testHook_setCandidateKey(key, stage: .proofOfPossession, fullBootstrap: true)
        XCTAssertNil(store.key(sensor: "DXCMab", slot: 2))
        XCTAssertEqual(controlWrites(p.receiveControl(Data([0x0D, 0x00]))), [Data([0x06, 0x19])])
        XCTAssertNil(store.key(sensor: "DXCMab", slot: 2))
        XCTAssertEqual(p.receiveControl(Data([0x06, 0x01])), [.authenticated])
        XCTAssertEqual(store.key(sensor: "DXCMab", slot: 2), key)
    }

    func testLegacyBondPathConfirmsOnPairResponse() {
        let (p, store) = pairing(savedKey: false, code: "1234")
        p.testHook_setCandidateKey(key, stage: .keepAlive, fullBootstrap: true)
        XCTAssertEqual(controlWrites(p.receiveControl(Data([0x06, 0x00]))), [Data([0x07])])
        XCTAssertTrue(p.receiveControl(Data([0x07, 0x00])).isEmpty)
        XCTAssertNil(store.key(sensor: "DXCMab", slot: 2))
        XCTAssertEqual(p.receiveControl(Data([0x08, 0x01])), [.authenticated])
        XCTAssertEqual(store.key(sensor: "DXCMab", slot: 2), key)
    }

    func testCertificateRequestEncodesLittleEndianLength() {
        let req = DirectConnect_G7Pairing.certificateRequest(phase: 0)
        XCTAssertEqual(req.prefix(2), Data([0x0B, 0x00]))
        XCTAssertEqual(req.dcUInt32LE(at: 2), UInt32(DirectConnect_G7Crypto.certificatePartA.count))
        XCTAssertEqual(DirectConnect_G7Pairing.certificateRequest(phase: 2), Data([0x0B, 0x02, 0, 0, 0, 0]))
    }

    func testCertificateExchangeAdvancesInOrder() {
        let (p, _) = pairing(savedKey: false, code: "1234")
        p.testHook_setCandidateKey(key, stage: .certificateExchange, fullBootstrap: true)
        // Phase 0 announces 10 remote bytes; we answer with part A on the stream and request phase 1.
        XCTAssertTrue(p.receiveControl(Data([0x0B, 0x00, 0x00, 0x0A, 0, 0, 0])).isEmpty)
        let events = p.receiveStream(Data(repeating: 0xEE, count: 10))
        XCTAssertEqual(streamWrites(events).map(\.data).reduce(Data(), +), DirectConnect_G7Crypto.certificatePartA)
        XCTAssertEqual(controlWrites(events), [DirectConnect_G7Pairing.certificateRequest(phase: 1)])
        // An out-of-order phase fails.
        guard case .failed = p.receiveControl(Data([0x0B, 0x00, 0x02, 0, 0, 0, 0])).first else { return XCTFail() }
    }

    func testResetForConnectionKeepsSavedKey() {
        let (p, store) = pairing(savedKey: true)
        _ = p.start()
        p.resetForConnection()
        XCTAssertEqual(store.key(sensor: "DXCMab", slot: 2), key)
        XCTAssertEqual(p.stage, .idle)
        XCTAssertEqual(p.start(), .writes([DirectConnect_AuthWrite(target: .control, data: Data([0x02]) + token + Data([0x02]), delay: 0)]))
    }
}
