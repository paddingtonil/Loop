//
//  DirectConnect_G7CryptoTests.swift
//  LoopTests
//
//  Concept & design by Taylor Patterson. Coded & tested by Claude Code in October 2026.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.
//

import XCTest
import CryptoKit
@testable import Loop

final class DirectConnect_G7CryptoTests: XCTestCase {
    func testAESECBMatchesFIPS197Vector() throws {
        let key = Data(dcHex: "000102030405060708090a0b0c0d0e0f")!
        let plain = Data(dcHex: "00112233445566778899aabbccddeeff")!
        XCTAssertEqual(try DirectConnect_G7Crypto.aesECB(plain, key: key), Data(dcHex: "69c4e0d86a7b0430d8cdb78070b4c55a"))
    }

    func testChallengeHashIsFirstEightBytesOfDoubledChallenge() throws {
        let key = Data(repeating: 0x11, count: 16)
        let challenge = Data(dcHex: "0102030405060708")!
        let full = try DirectConnect_G7Crypto.aesECB(challenge + challenge, key: key)
        XCTAssertEqual(try DirectConnect_G7Crypto.challengeHash(challenge, key: key), full.prefix(8))
    }

    func testChallengeHashRejectsWrongLength() {
        XCTAssertThrowsError(try DirectConnect_G7Crypto.challengeHash(Data(repeating: 1, count: 7), key: Data(repeating: 0, count: 16)))
    }

    func testPasswordScalar() throws {
        let s4 = try DirectConnect_G7Crypto.passwordScalar(code: "1234")
        XCTAssertEqual(s4, Data(repeating: 0, count: 28) + Data("1234".utf8))
        let s6 = try DirectConnect_G7Crypto.passwordScalar(code: "123456")
        XCTAssertEqual(s6, Data(repeating: 0, count: 24) + Data("00123456".utf8))
        XCTAssertThrowsError(try DirectConnect_G7Crypto.passwordScalar(code: ""))
    }

    func testGeneratorTimesOneIsGenerator() throws {
        let one = Data(repeating: 0, count: 31) + Data([1])
        XCTAssertEqual(try DirectConnect_G7Crypto.pointMultiply(DirectConnect_G7Crypto.generator, one), DirectConnect_G7Crypto.generator)
    }

    func testGeneratorMatchesCryptoKitPublicKeyDerivation() throws {
        // Cross-check the C arithmetic against CryptoKit: d·G must equal CryptoKit's public key for d.
        let key = P256.Signing.PrivateKey()
        let point = try DirectConnect_G7Crypto.pointMultiply(DirectConnect_G7Crypto.generator, key.rawRepresentation)
        XCTAssertEqual(point, key.publicKey.rawRepresentation)
    }

    func testPointAddThenSubtractRoundTrips() throws {
        let a = try DirectConnect_G7Crypto.generateKeyPair().publicKey
        let b = try DirectConnect_G7Crypto.generateKeyPair().publicKey
        let sum = try DirectConnect_G7Crypto.pointAdd(a, b)
        XCTAssertEqual(try DirectConnect_G7Crypto.pointSubtract(sum, b), a)
    }

    func testZeroKnowledgePacketValidatesForSameParty() throws {
        let pair = try DirectConnect_G7Crypto.generateKeyPair()
        let raw = try DirectConnect_G7Crypto.makeZKPacket(privateKey: pair.privateKey, publicKey: pair.publicKey, base: nil, party: DirectConnect_G7Crypto.clientParty)
        XCTAssertEqual(raw.count, 160)
        let packet = try DirectConnect_PakePacket(data: raw)
        XCTAssertNoThrow(try DirectConnect_G7Crypto.validateZKPacket(packet, base: DirectConnect_G7Crypto.generator, party: DirectConnect_G7Crypto.clientParty))
    }

    func testZeroKnowledgePacketFailsForOtherParty() throws {
        let pair = try DirectConnect_G7Crypto.generateKeyPair()
        let raw = try DirectConnect_G7Crypto.makeZKPacket(privateKey: pair.privateKey, publicKey: pair.publicKey, base: nil, party: DirectConnect_G7Crypto.clientParty)
        XCTAssertThrowsError(try DirectConnect_G7Crypto.validateZKPacket(try DirectConnect_PakePacket(data: raw), base: DirectConnect_G7Crypto.generator, party: DirectConnect_G7Crypto.serverParty))
    }

    func testPakePacketRejectsOffCurvePoint() {
        XCTAssertThrowsError(try DirectConnect_PakePacket(data: Data(repeating: 0x01, count: 160)))
    }

    func testPakePacketRejectsShortPayload() {
        XCTAssertThrowsError(try DirectConnect_PakePacket(data: Data(repeating: 0x01, count: 100)))
    }

    func testJPAKERoundOneAndTwoReplyWithValidClientPackets() throws {
        // A simulated sensor sends valid server-party round-1/2 packets; DirectConnect must
        // accept them and reply with packets that validate as client-party proofs.
        let jpake = try DirectConnect_JPAKE(pairingCode: "1234")
        for phase: UInt8 in [0, 1] {
            let server = try DirectConnect_G7Crypto.generateKeyPair()
            let serverPacket = try DirectConnect_G7Crypto.makeZKPacket(privateKey: server.privateKey, publicKey: server.publicKey, base: nil, party: DirectConnect_G7Crypto.serverParty)
            let reply = try jpake.handleRemote(phase: phase, payload: serverPacket)
            XCTAssertNil(reply.derivedKey)
            XCTAssertNoThrow(try DirectConnect_G7Crypto.validateZKPacket(try DirectConnect_PakePacket(data: reply.localPacket), base: DirectConnect_G7Crypto.generator, party: DirectConnect_G7Crypto.clientParty))
        }
    }

    func testJPAKEFullExchangeDerivesMatchingKeys() throws {
        // Run both sides of J-PAKE with the same code: the client under test and a reference
        // server built from the same primitives. Both must derive the same 16-byte key.
        let code = "4821"
        let client = try DirectConnect_JPAKE(pairingCode: code)
        let server = try ReferenceServer(code: code)

        let c1 = try client.handleRemote(phase: 0, payload: try server.round1()).localPacket
        let c2 = try client.handleRemote(phase: 1, payload: try server.round2()).localPacket
        try server.receiveClientRounds(c1, c2)
        let final = try client.handleRemote(phase: 2, payload: try server.round3())
        try server.receiveClientRound3(final.localPacket)

        XCTAssertEqual(final.derivedKey?.count, 16)
        XCTAssertEqual(final.derivedKey, try server.derivedKey())
    }

    func testJPAKEWrongCodeDerivesDifferentKeyOrFails() throws {
        let client = try DirectConnect_JPAKE(pairingCode: "1111")
        let server = try ReferenceServer(code: "2222")
        let c1 = try client.handleRemote(phase: 0, payload: try server.round1()).localPacket
        let c2 = try client.handleRemote(phase: 1, payload: try server.round2()).localPacket
        try server.receiveClientRounds(c1, c2)
        let final: (localPacket: Data, derivedKey: Data?)
        do {
            final = try client.handleRemote(phase: 2, payload: try server.round3())
        } catch {
            return // Rejecting the exchange is a correct outcome for a wrong code.
        }
        try server.receiveClientRound3(final.localPacket)
        XCTAssertNotEqual(final.derivedKey, try server.derivedKey())
    }

    func testCertificateConstantsAreDER() {
        XCTAssertEqual(Array(DirectConnect_G7Crypto.certificatePartA.prefix(2)), [0x30, 0x82])
        XCTAssertEqual(Array(DirectConnect_G7Crypto.certificatePartB.prefix(2)), [0x30, 0x82])
        XCTAssertEqual(DirectConnect_G7Crypto.proofSigningScalar.count, 32)
    }

    func testProofSignatureVerifiesWithMatchingPublicKey() throws {
        let challenge = Data(repeating: 0xAB, count: 16)
        let raw = try DirectConnect_G7Crypto.proofSignature(challenge: challenge)
        XCTAssertEqual(raw.count, 64)
        let key = try P256.Signing.PrivateKey(rawRepresentation: DirectConnect_G7Crypto.proofSigningScalar)
        let sig = try P256.Signing.ECDSASignature(rawRepresentation: raw)
        XCTAssertTrue(key.publicKey.isValidSignature(sig, for: SHA256.hash(data: challenge)))
    }

    func testMemoryKeyStoreScopesBySensorAndSlot() {
        let store = DirectConnect_MemoryKeyStore()
        store.save(Data(repeating: 1, count: 16), sensor: "DXCMab", slot: 2)
        XCTAssertNotNil(store.key(sensor: "DXCMab", slot: 2))
        XCTAssertNil(store.key(sensor: "DXCMab", slot: 3))
        XCTAssertNil(store.key(sensor: "DXCMcd", slot: 2))
        store.delete(sensor: "DXCMab")
        XCTAssertNil(store.key(sensor: "DXCMab", slot: 2))
    }
}

/// The sensor side of the J-PAKE exchange, written from the standard J-PAKE equations with the
/// party roles swapped. It exists only to prove the client derives the key a real peer would.
private final class ReferenceServer {
    typealias C = DirectConnect_G7Crypto
    let s: Data
    let x3 = try! C.generateKeyPair()
    let x4 = try! C.generateKeyPair()
    var g1: Data?
    var g2: Data?
    var clientA: Data?

    init(code: String) throws {
        s = try C.passwordScalar(code: code)
    }

    func round1() throws -> Data {
        try C.makeZKPacket(privateKey: x3.privateKey, publicKey: x3.publicKey, base: nil, party: C.serverParty)
    }

    func round2() throws -> Data {
        try C.makeZKPacket(privateKey: x4.privateKey, publicKey: x4.publicKey, base: nil, party: C.serverParty)
    }

    func receiveClientRounds(_ r1: Data, _ r2: Data) throws {
        g1 = try DirectConnect_PakePacket(data: r1).publicKey
        g2 = try DirectConnect_PakePacket(data: r2).publicKey
    }

    func round3() throws -> Data {
        // B = (G1 + G2 + G3)^(x4·s), proved with base G1 + G2 + G3.
        let base = try C.pointAdd(try C.pointAdd(g1!, g2!), x3.publicKey)
        let x4s = try C.scalarMultiplyModN(x4.privateKey, s)
        let b = try C.pointMultiply(base, x4s)
        return try C.makeZKPacket(privateKey: x4s, publicKey: b, base: base, party: C.serverParty)
    }

    func receiveClientRound3(_ r3: Data) throws {
        clientA = try DirectConnect_PakePacket(data: r3).publicKey
    }

    func derivedKey() throws -> Data {
        // K = (A − G2^(x4·s))^x4, key = SHA256(K.x)[0..<16].
        let x4s = try C.scalarMultiplyModN(x4.privateKey, s)
        let k = try C.pointMultiply(try C.pointSubtract(clientA!, try C.pointMultiply(g2!, x4s)), x4.privateKey)
        return Data(SHA256.hash(data: k.prefix(32))).prefix(16)
    }
}
