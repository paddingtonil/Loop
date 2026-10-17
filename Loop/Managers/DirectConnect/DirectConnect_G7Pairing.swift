//
//  DirectConnect_G7Pairing.swift
//  Loop (AID) PowerPack — based on LoopKit/Loop.
//  DirectConnect — G7 authentication and ownership state machine (bytes in, writes out).
//  Idea by Taylor Patterson. Coded by Claude Code.
//  Portions derived from xDrip4iOS (https://github.com/JohanDegraeve/xdripswift), GPL-3.0.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.

import Foundation
import LoopKit
import Security

enum DirectConnect_AuthCharacteristic: Equatable {
    /// Receive_Authentication (F8083535): small control packets.
    case control
    /// Auth_Stream (F8083538): J-PAKE, certificate and signature payloads in 20-byte fragments.
    case stream
}

struct DirectConnect_AuthWrite: Equatable {
    let target: DirectConnect_AuthCharacteristic
    let data: Data
    /// Seconds after the event is handled at which to write. Stream writes have no
    /// acknowledgement, so they are spaced to avoid overrunning the sensor.
    let delay: TimeInterval
}

enum DirectConnect_PairingEvent: Equatable {
    case writes([DirectConnect_AuthWrite])
    /// Data access is granted for this connection.
    case authenticated
    /// The saved key was refused. Another app may now own this slot; stop reconnecting.
    case rejectedSavedKey
    /// The sensor knows the key but reports incomplete ownership; reconnect and pair again.
    case needsCleanReconnect
    /// The sensor refused the applicator code during first pairing.
    case codeRejected
    /// The sensor refused a step of the code exchange. J-PAKE checks the code only at key
    /// confirmation (`codeRejected`), so this does not mean the code is wrong.
    case pakeRefused
    /// The sensor accepted the code-derived key but refused the certificate step.
    case certificateRefused
    case failed(String)
}

/// Drives one sensor's authentication. It never touches CoreBluetooth: the caller feeds it
/// notification bytes and performs the writes it returns, which keeps it unit-testable.
///
/// Two paths:
/// - **Short auth** (saved key): 02 token slot → 03 hash challenge → 04 response → 05 status.
/// - **Full ownership** (first pairing): J-PAKE phases 0–2 → short auth with the derived key →
///   certificate phases 0–2 → proof of possession → keep-alive. The derived key is written to
///   the key store only when the sensor confirms ownership, so an interrupted or refused attempt
///   can never leave a bad key behind for later reconnects.
final class DirectConnect_G7Pairing {
    enum Stage: String {
        case idle
        case authenticating
        case certificateExchange
        case proofOfPossession
        case keepAlive
        case bondRequest
        case pairConfirmation
        case authenticated
    }

    enum KeepAliveAction: Equatable {
        case completeOwnership
        case requestLegacyBond
        case ignore
    }

    static let streamPacketSpacing: TimeInterval = 0.04
    private static let pakePayloadSize = 160
    private static let proofPayloadSize = 64
    private static let maxCertificateSize = 4096

    private let log = DiagnosticLog(category: "DirectConnect.Pairing")

    let sensorName: String
    let slot: UInt8
    var pairingCode: String?
    /// When true, a saved key is ignored and ownership is established again with the code. Used
    /// while searching for a sensor, so a key saved for an old sensor cannot re-adopt it.
    var forceFullPairing = false
    private let keyStore: DirectConnect_KeyStoring
    private let tokenSource: () -> Data

    private(set) var stage: Stage = .idle
    private var streamBuffer = Data()
    private var started = false
    private var challengeAnswered = false
    private var usingFullBootstrap = false
    private var certificateExchangeStarted = false
    private var pendingPakePhase: UInt8?
    private var pendingCertificatePhase: UInt8?
    private var pendingCertificateSize: Int?
    private var expectedCertificatePhase: UInt8 = 0
    private var pendingProofStatus: Data?
    private var jpake: DirectConnect_JPAKE?
    private var candidateKey: Data?

    init(sensorName: String,
         pairingCode: String?,
         slot: UInt8 = 0x02,
         keyStore: DirectConnect_KeyStoring,
         tokenSource: @escaping () -> Data = DirectConnect_G7Pairing.randomToken)
    {
        self.sensorName = sensorName
        self.pairingCode = pairingCode
        self.slot = slot
        self.keyStore = keyStore
        self.tokenSource = tokenSource
    }

    static func randomToken() -> Data {
        // Dexcom uses the first eight bytes of a fresh UUID as the single-use token.
        let uuid = UUID().uuid
        return Data([uuid.0, uuid.1, uuid.2, uuid.3, uuid.4, uuid.5, uuid.6, uuid.7])
    }

    var hasSavedKey: Bool {
        keyStore.key(sensor: sensorName, slot: slot) != nil
    }

    /// Clears per-connection progress. A confirmed key in the key store is kept.
    func resetForConnection() {
        stage = .idle
        streamBuffer.removeAll(keepingCapacity: true)
        started = false
        challengeAnswered = false
        usingFullBootstrap = false
        certificateExchangeStarted = false
        pendingPakePhase = nil
        pendingCertificatePhase = nil
        pendingCertificateSize = nil
        expectedCertificatePhase = 0
        pendingProofStatus = nil
        jpake = nil
        candidateKey = nil
    }

    /// Call once both authentication characteristics are notifying.
    func start() -> DirectConnect_PairingEvent {
        guard !started else { return .writes([]) }
        started = true
        stage = .authenticating

        if hasSavedKey && !forceFullPairing {
            usingFullBootstrap = false
            log.default("Starting short authentication for %{public}@", sensorName)
            return .writes([write(.control, authRequest())])
        }

        guard let code = pairingCode, !code.isEmpty else {
            return .failed("No saved key and no applicator code")
        }
        do {
            jpake = try DirectConnect_JPAKE(pairingCode: code)
        } catch {
            return .failed("Could not start J-PAKE: \(error)")
        }
        usingFullBootstrap = true
        log.default("Starting full ownership pairing for %{public}@", sensorName)
        return .writes([write(.control, Data([DirectConnect_G7Opcode.exchangePake.rawValue, 0x00]))])
    }

    // MARK: - Inputs

    func receiveStream(_ data: Data) -> [DirectConnect_PairingEvent] {
        guard stage != .idle else { return [] }
        // Notification boundaries are not message boundaries; each phase consumes only its
        // documented byte count from this buffer.
        streamBuffer.append(data)
        return processPendingPake() + processPendingCertificate() + processPendingProof()
    }

    func receiveControl(_ data: Data) -> [DirectConnect_PairingEvent] {
        guard let first = data.first, let opcode = DirectConnect_G7Opcode(rawValue: first) else {
            return []
        }

        switch opcode {
        case .authRequestRx:
            return handleAuthRequest(data)

        case .authChallengeRx:
            return handleAuthStatus(data)

        case .exchangePake:
            guard data.count >= 3, data.dcByte(at: 1) == 0 else {
                // J-PAKE cannot detect a wrong code before key confirmation (handleAuthStatus).
                return [.pakeRefused]
            }
            pendingPakePhase = data.dcByte(at: 2)
            return processPendingPake()

        case .certificateExchange:
            return handleCertificateStatus(data)

        case .proofOfPossession:
            guard stage == .certificateExchange, data.count == 18, data.dcByte(at: 1) == 0 else {
                return [.failed("Proof-of-possession request was invalid")]
            }
            pendingProofStatus = Data(data)
            return processPendingProof()

        case .authStatus:
            guard stage == .proofOfPossession else { return [] }
            stage = .keepAlive
            return [.writes([write(.control, Data([DirectConnect_G7Opcode.keepAlive.rawValue, 0x19]))])]

        case .keepAlive:
            guard stage == .keepAlive else { return [] }
            switch Self.keepAliveAction(data) {
            case .completeOwnership:
                return confirmOwnership()
            case .requestLegacyBond:
                stage = .bondRequest
                return [.writes([write(.control, Data([DirectConnect_G7Opcode.bondRequest.rawValue]))])]
            case .ignore:
                return []
            }

        case .bondRequest:
            guard stage == .bondRequest, data == Data([DirectConnect_G7Opcode.bondRequest.rawValue, 0x00]) else { return [] }
            stage = .pairConfirmation
            return []

        case .pairRequestRx:
            guard stage == .pairConfirmation, data == Data([DirectConnect_G7Opcode.pairRequestRx.rawValue, 0x01]) else { return [] }
            return confirmOwnership()

        default:
            return []
        }
    }

    static func keepAliveAction(_ data: Data) -> KeepAliveAction {
        switch data {
        case Data([DirectConnect_G7Opcode.keepAlive.rawValue, 0x01]): return .completeOwnership
        case Data([DirectConnect_G7Opcode.keepAlive.rawValue, 0x00]): return .requestLegacyBond
        default: return .ignore
        }
    }

    static func certificateRequest(phase: UInt8) -> Data {
        let size: UInt32
        switch phase {
        case 0: size = UInt32(DirectConnect_G7Crypto.certificatePartA.count)
        case 1: size = UInt32(DirectConnect_G7Crypto.certificatePartB.count)
        default: size = 0
        }
        // The 32-bit length is little-endian; a big-endian length makes the sensor disconnect.
        return Data([DirectConnect_G7Opcode.certificateExchange.rawValue, phase]) + Data.dcUInt32LEBytes(size)
    }

    // MARK: - Short auth

    private func authRequest() -> Data {
        Data([DirectConnect_G7Opcode.authRequest2Tx.rawValue]) + tokenSource().prefix(8) + Data([slot])
    }

    private func handleAuthRequest(_ data: Data) -> [DirectConnect_PairingEvent] {
        guard !challengeAnswered, let message = DirectConnect_AuthRequestRx(data: data) else { return [] }
        guard let key = candidateKey ?? (forceFullPairing ? nil : keyStore.key(sensor: sensorName, slot: slot)) else {
            return [.failed("No key available for the challenge")]
        }
        do {
            let hash = try DirectConnect_G7Crypto.challengeHash(message.challenge, key: key)
            challengeAnswered = true
            return [.writes([write(.control, Data([DirectConnect_G7Opcode.authChallengeTx.rawValue]) + hash)])]
        } catch {
            return [.failed("Could not answer the challenge: \(error)")]
        }
    }

    private func handleAuthStatus(_ data: Data) -> [DirectConnect_PairingEvent] {
        guard let status = DirectConnect_AuthStatusRx(data: data) else {
            return [.failed("Could not parse authentication status")]
        }

        if usingFullBootstrap {
            guard status.authenticated else {
                // The derived key was refused; with a fresh J-PAKE this means the code was wrong.
                candidateKey = nil
                return [.codeRejected]
            }
            guard !certificateExchangeStarted else { return [] }
            return startCertificateExchange()
        }

        if status.authenticated && status.paired {
            stage = .authenticated
            return [.authenticated]
        }
        if status.authenticated {
            keyStore.delete(sensor: sensorName)
            return [.needsCleanReconnect]
        }
        // Do not erase the key or start a new ownership exchange: that could take the sensor
        // away from whichever app now owns it.
        return [.rejectedSavedKey]
    }

    // MARK: - J-PAKE

    private func processPendingPake() -> [DirectConnect_PairingEvent] {
        guard let phase = pendingPakePhase, streamBuffer.count >= Self.pakePayloadSize else { return [] }
        let payload = Data(streamBuffer.prefix(Self.pakePayloadSize))
        streamBuffer.removeFirst(Self.pakePayloadSize)
        pendingPakePhase = nil

        guard let jpake = jpake else { return [.failed("J-PAKE payload without an active exchange")] }
        do {
            let result = try jpake.handleRemote(phase: phase, payload: payload)
            let control: Data
            if phase >= 2 {
                guard let key = result.derivedKey else { return [.failed("J-PAKE produced no key")] }
                candidateKey = key
                control = authRequest()
            } else {
                control = Data([DirectConnect_G7Opcode.exchangePake.rawValue, phase + 1])
            }
            log.default("J-PAKE phase %d complete", Int(phase))
            return [exchange(stream: result.localPacket.dcChunked(into: 20), control: control)]
        } catch {
            return [.failed("J-PAKE phase \(phase) failed: \(error)")]
        }
    }

    // MARK: - Certificates

    private func startCertificateExchange() -> [DirectConnect_PairingEvent] {
        certificateExchangeStarted = true
        stage = .certificateExchange
        expectedCertificatePhase = 0
        pendingCertificatePhase = nil
        pendingCertificateSize = nil
        streamBuffer.removeAll(keepingCapacity: true)
        return [.writes([write(.control, Self.certificateRequest(phase: 0))])]
    }

    private func handleCertificateStatus(_ data: Data) -> [DirectConnect_PairingEvent] {
        guard stage == .certificateExchange, data.count >= 7 else {
            return [.failed("Certificate exchange was rejected")]
        }
        guard data.dcByte(at: 1) == 0 else {
            // A new G7 refused this step for about 20 minutes after insertion on 2026-10-16,
            // then accepted it with the same code.
            return [.certificateRefused]
        }
        let phase = data.dcByte(at: 2)
        guard phase == expectedCertificatePhase, phase <= 2 else {
            return [.failed("Certificate phase out of order")]
        }
        let size = Int(data.dcUInt32LE(at: 3))
        guard size <= Self.maxCertificateSize, phase < 2 || size == 0 else {
            return [.failed("Certificate size invalid")]
        }
        pendingCertificatePhase = phase
        pendingCertificateSize = size
        return processPendingCertificate()
    }

    private func processPendingCertificate() -> [DirectConnect_PairingEvent] {
        guard let phase = pendingCertificatePhase, let size = pendingCertificateSize, streamBuffer.count >= size else {
            return []
        }
        if size > 0 { streamBuffer.removeFirst(size) }
        pendingCertificatePhase = nil
        pendingCertificateSize = nil
        expectedCertificatePhase = phase &+ 1

        switch phase {
        case 0:
            return [exchange(stream: DirectConnect_G7Crypto.certificatePartA.dcChunked(into: 20), control: Self.certificateRequest(phase: 1))]
        case 1:
            return [exchange(stream: DirectConnect_G7Crypto.certificatePartB.dcChunked(into: 20), control: Self.certificateRequest(phase: 2))]
        default:
            return [.writes([write(.control, proofChallengeRequest())])]
        }
    }

    private func proofChallengeRequest() -> Data {
        var challenge = Data(count: 16)
        let status = challenge.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        if status != errSecSuccess {
            challenge = Self.randomToken() + Self.randomToken()
        }
        return Data([DirectConnect_G7Opcode.proofOfPossession.rawValue]) + challenge
    }

    // MARK: - Proof of possession

    private func processPendingProof() -> [DirectConnect_PairingEvent] {
        guard let status = pendingProofStatus, streamBuffer.count >= Self.proofPayloadSize else { return [] }
        streamBuffer.removeFirst(Self.proofPayloadSize)
        pendingProofStatus = nil
        do {
            let challenge = status.subdata(in: (status.startIndex + 2)..<(status.startIndex + 18))
            let signature = try DirectConnect_G7Crypto.proofSignature(challenge: challenge)
            stage = .proofOfPossession
            return [exchange(stream: signature.dcChunked(into: 20),
                             control: Data([DirectConnect_G7Opcode.authStatus.rawValue, 0x00, 0x02]))]
        } catch {
            return [.failed("Proof-of-possession signing failed")]
        }
    }

    // MARK: - Completion

    private func confirmOwnership() -> [DirectConnect_PairingEvent] {
        guard let key = candidateKey else {
            return [.failed("Ownership confirmed without a candidate key")]
        }
        keyStore.save(key, sensor: sensorName, slot: slot)
        stage = .authenticated
        log.default("Ownership confirmed; key saved for %{public}@", sensorName)
        return [.authenticated]
    }

    // MARK: - Write helpers

    private func write(_ target: DirectConnect_AuthCharacteristic, _ data: Data, delay: TimeInterval = 0) -> DirectConnect_AuthWrite {
        DirectConnect_AuthWrite(target: target, data: data, delay: delay)
    }

    /// Stream fragments first, then the control packet telling the sensor to process them.
    private func exchange(stream: [Data], control: Data) -> DirectConnect_PairingEvent {
        var writes = stream.enumerated().map { index, packet in
            write(.stream, packet, delay: Self.streamPacketSpacing * Double(index))
        }
        writes.append(write(.control, control, delay: Self.streamPacketSpacing * Double(stream.count + 1)))
        return .writes(writes)
    }

    // MARK: - Test seam

    /// Sets an in-progress ownership state so confirmation rules can be tested without a sensor.
    func testHook_setCandidateKey(_ key: Data, stage: Stage, fullBootstrap: Bool) {
        candidateKey = key
        self.stage = stage
        started = true
        usingFullBootstrap = fullBootstrap
        if stage == .certificateExchange {
            certificateExchangeStarted = true
            expectedCertificatePhase = 0
        }
    }
}
