//
//  DirectConnect_G7Crypto.swift
//  Loop (AID) PowerPack — based on LoopKit/Loop.
//  DirectConnect — AES challenge hashing, P-256 J-PAKE and proof-of-possession signing.
//  Idea by Taylor Patterson. Coded by Claude Code.
//  Portions derived from xDrip4iOS (https://github.com/JohanDegraeve/xdripswift), GPL-3.0.
//  The J-PAKE packet order and party identities follow xDrip4iOS, which cross-checked them
//  against Juggluco (https://github.com/j-kaltes/Juggluco).
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.

import Foundation
import CommonCrypto
import CryptoKit

enum DirectConnect_G7CryptoError: Error, Equatable {
    case invalidChallenge
    case missingPairingCode
    case invalidPakePacket
    case validationFailed
    case ecc(String)
    case aes(Int32)
    case signatureFailed
}

/// One J-PAKE proof: public point, proof point (V) and proof scalar (r). 64 + 64 + 32 bytes.
struct DirectConnect_PakePacket {
    static let size = 160

    let publicKey: Data
    let proofPoint: Data
    let proofScalar: Data

    init(data: Data) throws {
        guard data.count >= Self.size else { throw DirectConnect_G7CryptoError.invalidPakePacket }
        let bytes = Data(data.prefix(Self.size))
        publicKey = bytes.subdata(in: 0..<64)
        proofPoint = bytes.subdata(in: 64..<128)
        proofScalar = bytes.subdata(in: 128..<160)
        guard DirectConnect_G7Crypto.isValidPoint(publicKey), DirectConnect_G7Crypto.isValidPoint(proofPoint) else {
            throw DirectConnect_G7CryptoError.validationFailed
        }
    }
}

enum DirectConnect_G7Crypto {
    static let scalarSize = 32
    static let pointSize = 64

    /// Standard P-256 generator, raw X || Y.
    static let generator = Data(dcHex:
        "6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296" +
        "4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5")!

    static let clientParty = Data("client".utf8)
    static let serverParty = Data("server".utf8)

    static let certificatePartA = Data(dcHex: DirectConnect_G7Certificates.partAHex)!
    static let certificatePartB = Data(dcHex: DirectConnect_G7Certificates.partBHex)!
    static let proofSigningScalar = Data(dcHex: DirectConnect_G7Certificates.proofScalarHex)!

    // MARK: - AES

    /// AES-128 in ECB mode without padding; input must be a multiple of 16 bytes.
    static func aesECB(_ data: Data, key: Data) throws -> Data {
        var output = Data(count: data.count + kCCBlockSizeAES128)
        var written = 0
        let outputCapacity = output.count
        let status = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                            keyBytes.baseAddress, key.count, nil,
                            input.baseAddress, data.count,
                            out.baseAddress, outputCapacity, &written)
                }
            }
        }
        guard Int(status) == kCCSuccess else { throw DirectConnect_G7CryptoError.aes(status) }
        return output.prefix(written)
    }

    /// Dexcom challenge response: AES(challenge || challenge) truncated to 8 bytes.
    static func challengeHash(_ challenge: Data, key: Data) throws -> Data {
        guard challenge.count == 8 else { throw DirectConnect_G7CryptoError.invalidChallenge }
        return try aesECB(challenge + challenge, key: key).prefix(8)
    }

    // MARK: - Scalars and points

    /// The applicator code as a J-PAKE scalar. Six-digit codes carry an ASCII "00" prefix.
    static func passwordScalar(code: String) throws -> Data {
        guard !code.isEmpty else { throw DirectConnect_G7CryptoError.missingPairingCode }
        var bytes = Data(code.utf8)
        if code.count == 6 { bytes = Data("00".utf8) + bytes }
        var result = Data(count: scalarSize)
        bytes.withUnsafeBytes { input in
            result.withUnsafeMutableBytes { out in
                DirectConnect_ECCScalarFromBytes(input.bindMemory(to: UInt8.self).baseAddress, bytes.count, out.bindMemory(to: UInt8.self).baseAddress)
            }
        }
        return result
    }

    static func generateKeyPair() throws -> (publicKey: Data, privateKey: Data) {
        var pub = Data(count: pointSize)
        var priv = Data(count: scalarSize)
        let ok = pub.withUnsafeMutableBytes { p in
            priv.withUnsafeMutableBytes { k in
                DirectConnect_ECCGenerateKeyPair(p.bindMemory(to: UInt8.self).baseAddress, k.bindMemory(to: UInt8.self).baseAddress)
            }
        }
        guard ok else { throw DirectConnect_G7CryptoError.ecc("key generation") }
        return (pub, priv)
    }

    static func isValidPoint(_ point: Data) -> Bool {
        guard point.count == pointSize else { return false }
        return point.withUnsafeBytes { DirectConnect_ECCIsValidPoint($0.bindMemory(to: UInt8.self).baseAddress) }
    }

    static func pointAdd(_ left: Data, _ right: Data) throws -> Data {
        try binaryPointOp(left, right, name: "point add", DirectConnect_ECCPointAdd)
    }

    static func pointSubtract(_ left: Data, _ right: Data) throws -> Data {
        try binaryPointOp(left, right, name: "point subtract", DirectConnect_ECCPointSubtract)
    }

    static func pointMultiply(_ point: Data, _ scalar: Data) throws -> Data {
        guard point.count == pointSize, scalar.count == scalarSize else { throw DirectConnect_G7CryptoError.ecc("point multiply size") }
        return try binaryOp(point, scalar, outputSize: pointSize, name: "point multiply", DirectConnect_ECCPointMultiply)
    }

    static func scalarMultiplyModN(_ left: Data, _ right: Data) throws -> Data {
        guard left.count == scalarSize, right.count == scalarSize else { throw DirectConnect_G7CryptoError.ecc("scalar size") }
        return try binaryOp(left, right, outputSize: scalarSize, name: "scalar multiply", DirectConnect_ECCScalarMultiplyModN)
    }

    static func scalarSubtractModN(_ left: Data, _ right: Data) throws -> Data {
        guard left.count == scalarSize, right.count == scalarSize else { throw DirectConnect_G7CryptoError.ecc("scalar size") }
        return try binaryOp(left, right, outputSize: scalarSize, name: "scalar subtract", DirectConnect_ECCScalarSubtractModN)
    }

    static func randomScalar() throws -> Data {
        var result = Data(count: scalarSize)
        let ok = result.withUnsafeMutableBytes { DirectConnect_ECCScalarRandom($0.bindMemory(to: UInt8.self).baseAddress) }
        guard ok else { throw DirectConnect_G7CryptoError.ecc("random scalar") }
        return result
    }

    // MARK: - Zero-knowledge proofs

    /// Builds a 160-byte Schnorr proof that the sender knows `privateKey` for `publicKey`
    /// relative to `base` (the generator when nil).
    static func makeZKPacket(privateKey: Data, publicKey: Data, base: Data?, party: Data) throws -> Data {
        let basePoint = base ?? generator
        let v = try randomScalar()
        let proofPoint = try pointMultiply(basePoint, v)
        let h = zeroKnowledgeHash(base: basePoint, proofPoint: proofPoint, publicKey: publicKey, party: party)
        let r = try scalarSubtractModN(v, try scalarMultiplyModN(h, privateKey))
        return publicKey + proofPoint + r
    }

    /// Checks base·r + publicKey·h == proofPoint.
    static func validateZKPacket(_ packet: DirectConnect_PakePacket, base: Data, party: Data) throws {
        let h = zeroKnowledgeHash(base: base, proofPoint: packet.proofPoint, publicKey: packet.publicKey, party: party)
        let left = try pointMultiply(base, packet.proofScalar)
        let right = try pointMultiply(packet.publicKey, h)
        let combined: Data
        do {
            combined = try pointAdd(left, right)
        } catch {
            throw DirectConnect_G7CryptoError.validationFailed
        }
        guard combined == packet.proofPoint else { throw DirectConnect_G7CryptoError.validationFailed }
    }

    /// SHA-256 over length-prefixed (big-endian UInt32) uncompressed points and the party ID,
    /// reduced modulo the group order.
    static func zeroKnowledgeHash(base: Data, proofPoint: Data, publicKey: Data, party: Data) -> Data {
        var input = Data()
        for field in [Data([0x04]) + base, Data([0x04]) + proofPoint, Data([0x04]) + publicKey, party] {
            let length = UInt32(field.count).bigEndian
            withUnsafeBytes(of: length) { input.append(contentsOf: $0) }
            input.append(field)
        }
        let digest = Data(SHA256.hash(data: input))
        var reduced = Data(count: scalarSize)
        digest.withUnsafeBytes { d in
            reduced.withUnsafeMutableBytes { r in
                DirectConnect_ECCScalarReduceModN(d.bindMemory(to: UInt8.self).baseAddress, r.bindMemory(to: UInt8.self).baseAddress)
            }
        }
        return reduced
    }

    // MARK: - Proof of possession

    /// Signs SHA-256(challenge) with the fixed client key and returns raw r || s (64 bytes).
    static func proofSignature(challenge: Data) throws -> Data {
        do {
            let key = try P256.Signing.PrivateKey(rawRepresentation: proofSigningScalar)
            return try key.signature(for: SHA256.hash(data: challenge)).rawRepresentation
        } catch {
            throw DirectConnect_G7CryptoError.signatureFailed
        }
    }

    // MARK: - C bridging helpers

    private typealias BinaryCFunction = (UnsafePointer<UInt8>?, UnsafePointer<UInt8>?, UnsafeMutablePointer<UInt8>?) -> Bool

    private static func binaryPointOp(_ left: Data, _ right: Data, name: String, _ fn: BinaryCFunction) throws -> Data {
        guard left.count == pointSize, right.count == pointSize else { throw DirectConnect_G7CryptoError.ecc("\(name) size") }
        return try binaryOp(left, right, outputSize: pointSize, name: name, fn)
    }

    private static func binaryOp(_ left: Data, _ right: Data, outputSize: Int, name: String, _ fn: BinaryCFunction) throws -> Data {
        var result = Data(count: outputSize)
        let ok = left.withUnsafeBytes { l in
            right.withUnsafeBytes { r in
                result.withUnsafeMutableBytes { out in
                    fn(l.bindMemory(to: UInt8.self).baseAddress, r.bindMemory(to: UInt8.self).baseAddress, out.bindMemory(to: UInt8.self).baseAddress)
                }
            }
        }
        guard ok else { throw DirectConnect_G7CryptoError.ecc(name) }
        return result
    }
}

// MARK: - J-PAKE session

/// Client side of the three-phase G7 J-PAKE exchange. One instance lives for one ownership
/// attempt; the derived key is only a candidate until the sensor confirms ownership.
final class DirectConnect_JPAKE {
    private typealias C = DirectConnect_G7Crypto

    private let password: Data
    private let keyA: (publicKey: Data, privateKey: Data)
    private let keyB: (publicKey: Data, privateKey: Data)
    private var remoteRound1: DirectConnect_PakePacket?
    private var remoteRound2: DirectConnect_PakePacket?

    init(pairingCode: String) throws {
        password = try C.passwordScalar(code: pairingCode)
        keyA = try C.generateKeyPair()
        keyB = try C.generateKeyPair()
    }

    /// Validates the sensor's packet for `phase` (0, 1, 2) and returns this side's packet.
    /// Phase 2 also returns the derived 16-byte key.
    func handleRemote(phase: UInt8, payload: Data) throws -> (localPacket: Data, derivedKey: Data?) {
        let packet = try DirectConnect_PakePacket(data: payload)
        switch phase {
        case 0:
            try C.validateZKPacket(packet, base: C.generator, party: C.serverParty)
            remoteRound1 = packet
            return (try C.makeZKPacket(privateKey: keyA.privateKey, publicKey: keyA.publicKey, base: nil, party: C.clientParty), nil)

        case 1:
            try C.validateZKPacket(packet, base: C.generator, party: C.serverParty)
            remoteRound2 = packet
            return (try C.makeZKPacket(privateKey: keyB.privateKey, publicKey: keyB.publicKey, base: nil, party: C.clientParty), nil)

        case 2:
            guard let r1 = remoteRound1, let r2 = remoteRound2 else { throw DirectConnect_G7CryptoError.invalidPakePacket }
            // The sensor proves B = (G1 + G2 + G3)^(x4·s).
            let remoteBase = try C.pointAdd(try C.pointAdd(keyA.publicKey, keyB.publicKey), r1.publicKey)
            try C.validateZKPacket(packet, base: remoteBase, party: C.serverParty)

            // A = (G1 + G3 + G4)^(x2·s), proved with that sum as base.
            let x2s = try C.scalarMultiplyModN(keyB.privateKey, password)
            let localBase = try C.pointAdd(try C.pointAdd(keyA.publicKey, r1.publicKey), r2.publicKey)
            let a = try C.pointMultiply(localBase, x2s)
            let localPacket = try C.makeZKPacket(privateKey: x2s, publicKey: a, base: localBase, party: C.clientParty)

            // K = (B − G4^(x2·s))^x2; key = SHA-256(K.x)[0..<16].
            let k = try C.pointMultiply(try C.pointSubtract(packet.publicKey, try C.pointMultiply(r2.publicKey, x2s)), keyB.privateKey)
            let key = Data(SHA256.hash(data: k.prefix(32))).prefix(16)
            return (localPacket, Data(key))

        default:
            throw DirectConnect_G7CryptoError.invalidPakePacket
        }
    }
}
