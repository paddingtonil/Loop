# DirectConnect Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a PowerPack Exclusive built-in CGM option that pairs Loop directly with Dexcom G7 / ONE+ / Stelo sensors (no Dexcom app), with calibration, 15-day support, diagnostics, and user-configurable glucose alarms.

**Architecture:** A self-contained CGM driver inside the Loop app target. The Loop-facing layer (CGMManager conformance, persisted state, gap filling, Bluetooth manager) is adapted from LoopKit G7SensorKit (MIT). The pairing protocol, crypto, calibration, and diagnostic messages are adapted from xDrip4iOS 7.1.1 (GPL-3.0). Pure units (messages, crypto, pairing, calibration, alarms) take bytes/values in and return bytes/values out so they are unit-testable without Bluetooth.

**Tech Stack:** Swift 5, SwiftUI, CoreBluetooth, CryptoKit, CommonCrypto, C (micro-ecc P-256), LoopKit / LoopKitUI, XCTest.

**Spec:** `Loop/Documentation/DirectConnect/DirectConnect_DESIGN.md`

## Global Constraints

- Every new file is named `DirectConnect_<Name>` and lives under `Loop/{Managers,Resources,Views}/DirectConnect/`, `LoopTests/DirectConnect/`, or `Documentation/DirectConnect/`.
- Feature flag: `DirectConnect_FeatureFlags.isEnabled`, UserDefaults key `com.loopkit.Loop.directConnectFeatureEnabled`, default `false`.
- CGM plugin identifier: `PowerPackDirectConnectG7`. Display title: `Dexcom G7 / ONE+ / Stelo (DirectConnect)`.
- CBCentralManager restore identifier: `com.loopkit.Loop.DirectConnect` (must differ from G7SensorKit's `com.loudnate.CGMBLEKit`).
- Files containing xDrip4iOS-derived code carry: `Portions derived from xDrip4iOS (https://github.com/JohanDegraeve/xdripswift), GPL-3.0.`
- Swift file header style matches existing PowerPack files (`Loop (AID) PowerPack — based on LoopKit/Loop.` … `Coded by Claude Code.` … `Copyright © 2026 LoopKit Authors and Taylor Patterson.`).
- No compile-time dependency on G7SensorKit or any xDrip4iOS module. Data helpers are prefixed (`dc…`) so they cannot collide with extensions elsewhere in the Loop target.
- Shared key stored in Keychain, service `com.loopkit.Loop.DirectConnect`, account `<sensorName>.<slot hex>`.
- Bluetooth slot: `0x02` (mobile app).
- Alarm defaults and ranges exactly as spec §7.
- Two existing Loop files change, by anchor inserts only: `Loop/Managers/CGMManager.swift`, `Loop/Views/SettingsView.swift`. Plus `Loop.xcodeproj/project.pbxproj`.
- The agent does not build. The operator runs the test suite in Xcode at each **Checkpoint**.

## Review Focus

1. **Wrong applicator code** → J-PAKE round-3 validation fails; no key is saved; the setup screen shows the code error and the next connection retries with the corrected code. Test: Task 6 `testWrongCodeRejectionDoesNotPersistKey`.
2. **App killed mid-pairing** → the candidate key was never confirmed, so the next launch starts full pairing again rather than short auth with a bad key. Test: Task 6 `testDerivedKeyNotPersistedUntilOwnershipConfirmed`.
3. **Old sensor still advertising after a new one is added** → the old `DX..` name is skipped during new-sensor scan. Test: Task 3 `testScanSkipsPreviousSensorName`.
4. **Glucose bouncing around a threshold** → Low alarm does not re-fire every reading; it follows its repeat interval and retracts only when glucose is back above threshold. Test: Task 8 `testLowRepeatsOnlyAfterInterval`.
5. **User sets Low below Urgent Low** → settings model clamps so Urgent Low < Low < High always holds. Test: Task 1 `testThresholdOrderingIsEnforced`.

---

### Task 1: Feature flag and alarm settings model

**Files:**
- Create: `Loop/Resources/DirectConnect/DirectConnect_FeatureFlags.swift`
- Create: `Loop/Managers/DirectConnect/DirectConnect_AlarmSettings.swift`
- Test: `LoopTests/DirectConnect/DirectConnect_AlarmSettingsTests.swift`

**Interfaces:**
- Produces:
  - `enum DirectConnect_FeatureFlags { static var isEnabled: Bool; static var isActiveCGM: Bool }`
  - `enum DirectConnect_AlarmKind: String, CaseIterable { case urgentLow, low, high, risingFast, fallingFast, signalLoss, sensorExpiring, sensorEnded }`
  - `struct DirectConnect_AlarmSettings: Equatable` with `var urgentLowEnabled, lowEnabled, highEnabled, risingFastEnabled, fallingFastEnabled, signalLossEnabled, sensorExpiringEnabled, sensorEndedEnabled: Bool`; `var urgentLowThreshold, lowThreshold, highThreshold: Double` (mg/dL); `var risingRate, fallingRate: Double` (mg/dL/min, positive); `var signalLossMinutes: Double`; `var urgentLowRepeatMinutes, lowRepeatMinutes, highRepeatMinutes: Double`; `static let defaults`; `func normalized() -> DirectConnect_AlarmSettings`; `static func load(from: UserDefaults) -> Self`; `func save(to: UserDefaults)`.
  - Ranges: `static let urgentLowRange = 40.0...70.0`, `lowRange = 55.0...100.0`, `highRange = 120.0...400.0`, `rateRange = 2.0...5.0`, `signalLossRange = 10.0...60.0`, `urgentLowRepeatRange = 5.0...30.0`, `lowRepeatRange = 5.0...60.0`, `highRepeatRange = 15.0...240.0`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Loop

final class DirectConnect_AlarmSettingsTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: "DirectConnect_AlarmSettingsTests")
        defaults.removePersistentDomain(forName: "DirectConnect_AlarmSettingsTests")
    }

    func testDefaultsMatchSpec() {
        let s = DirectConnect_AlarmSettings.defaults
        XCTAssertEqual(s.urgentLowThreshold, 55); XCTAssertTrue(s.urgentLowEnabled); XCTAssertEqual(s.urgentLowRepeatMinutes, 5)
        XCTAssertEqual(s.lowThreshold, 70); XCTAssertTrue(s.lowEnabled); XCTAssertEqual(s.lowRepeatMinutes, 15)
        XCTAssertEqual(s.highThreshold, 250); XCTAssertTrue(s.highEnabled); XCTAssertEqual(s.highRepeatMinutes, 60)
        XCTAssertEqual(s.risingRate, 3); XCTAssertFalse(s.risingFastEnabled)
        XCTAssertEqual(s.fallingRate, 3); XCTAssertTrue(s.fallingFastEnabled)
        XCTAssertEqual(s.signalLossMinutes, 20); XCTAssertTrue(s.signalLossEnabled)
        XCTAssertTrue(s.sensorExpiringEnabled); XCTAssertTrue(s.sensorEndedEnabled)
    }

    func testLoadReturnsDefaultsWhenNothingSaved() {
        XCTAssertEqual(DirectConnect_AlarmSettings.load(from: defaults), .defaults)
    }

    func testSaveLoadRoundTrip() {
        var s = DirectConnect_AlarmSettings.defaults
        s.lowThreshold = 80; s.highEnabled = false; s.risingRate = 2.5
        s.save(to: defaults)
        XCTAssertEqual(DirectConnect_AlarmSettings.load(from: defaults), s)
    }

    func testValuesAreClampedToRanges() {
        var s = DirectConnect_AlarmSettings.defaults
        s.urgentLowThreshold = 10; s.highThreshold = 900; s.risingRate = 9; s.signalLossMinutes = 1
        let n = s.normalized()
        XCTAssertEqual(n.urgentLowThreshold, 40); XCTAssertEqual(n.highThreshold, 400)
        XCTAssertEqual(n.risingRate, 5); XCTAssertEqual(n.signalLossMinutes, 10)
    }

    func testThresholdOrderingIsEnforced() {
        var s = DirectConnect_AlarmSettings.defaults
        s.urgentLowThreshold = 65; s.lowThreshold = 60
        let n = s.normalized()
        XCTAssertLessThan(n.urgentLowThreshold, n.lowThreshold)
        XCTAssertLessThan(n.lowThreshold, n.highThreshold)
    }
}
```

- [ ] **Step 2: Run test to verify it fails** — Operator: Xcode ▸ LoopTests ▸ `DirectConnect_AlarmSettingsTests`. Expected: FAIL, "cannot find 'DirectConnect_AlarmSettings' in scope".

- [ ] **Step 3: Implement**

`DirectConnect_FeatureFlags.swift`:

```swift
enum DirectConnect_FeatureFlags {
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.enabled) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.enabled) }
    }

    /// Set by DirectConnect_G7CGMManager while it is Loop's CGM, so Settings can refuse to
    /// turn the feature off underneath an active glucose source.
    static var isActiveCGM: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.activeCGM) }
        set { UserDefaults.standard.set(newValue, forKey: Keys.activeCGM) }
    }

    enum Keys {
        static let enabled = "com.loopkit.Loop.directConnectFeatureEnabled"
        static let activeCGM = "com.loopkit.Loop.directConnect.isActiveCGM"
    }
}
```

`DirectConnect_AlarmSettings.swift`: struct with the fields above; `normalized()` clamps each value to its range, then enforces `urgentLow <= low - 5` (lowers urgentLow) and `low <= high - 20` (lowers low, then re-applies urgentLow rule); `load` reads keys `com.loopkit.Loop.directConnect.alarm.<fieldName>` with `object(forKey:) as? Double/Bool ?? default`; `save` writes `normalized()` values.

- [ ] **Step 4: Run test to verify it passes** — Operator runs the same tests. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Loop/Resources/DirectConnect Loop/Managers/DirectConnect/DirectConnect_AlarmSettings.swift LoopTests/DirectConnect/DirectConnect_AlarmSettingsTests.swift
git commit -m "DirectConnect: feature flag and alarm settings model"
```

---

### Task 2: Byte helpers, CRC, and G7 messages

**Files:**
- Create: `Loop/Managers/DirectConnect/DirectConnect_Bytes.swift`
- Create: `Loop/Managers/DirectConnect/DirectConnect_G7Messages.swift`
- Test: `LoopTests/DirectConnect/DirectConnect_G7MessagesTests.swift`

Source to adapt: G7SensorKit `Messages/G7GlucoseMessage.swift`, `G7CGMManager/G7BackfillMessage.swift`, `AlgorithmState.swift`, `Messages/ExtendedVersionMessage.swift`; xDrip4iOS `Dexcom/Generic/DexcomG7DiagnosticMessages.swift`, `AuthRequestRxMessage.swift`, `AuthChallengeRxMessage.swift`, `NSData+CRC.swift`, `DexcomTransmitterOpCode.swift` (only opcodes used here).

**Interfaces:**
- Produces:
  - `extension Data { func dcUInt16LE(at:) -> UInt16; func dcUInt32LE(at:) -> UInt32; func dcUInt24LE(at:) -> UInt32; var dcHex: String; init?(dcHex: String); var dcCRC16: UInt16; func dcAppendingCRC() -> Data; func dcChunked(into: Int) -> [Data] }`
  - `enum DirectConnect_G7Opcode: UInt8` — `authRequestTx=0x01, authRequest2Tx=0x02, authRequestRx=0x03, authChallengeTx=0x04, authChallengeRx=0x05, keepAlive=0x06, bondRequest=0x07, pairRequestRx=0x08, exchangePake=0x0A, certificateExchange=0x0B, proofOfPossession=0x0C, authStatus=0x0D, batteryStatus=0x22, calibrationBounds=0x32, calibrate=0x34, transmitterVersion=0x4A, glucose=0x4E, extendedVersion=0x52, backfillFinished=0x59`
  - `enum DirectConnect_AlgorithmState` (copy of G7SensorKit `AlgorithmState`, renamed, with `sensorFailed`, `isInWarmup`, `hasTemporaryError`, `hasReliableGlucose`, `isSessionEnded`).
  - `struct DirectConnect_G7GlucoseMessage: Equatable { responseStatus: UInt8; glucose: UInt16?; predicted: UInt16?; glucoseIsDisplayOnly: Bool; messageTimestamp: UInt32; age: UInt16; sequence: UInt16; algorithmState; trend: Double?; data: Data; var glucoseTimestamp: UInt32; var hasReliableGlucose: Bool; var trendType: GlucoseTrend?; var condition: GlucoseCondition?; init?(data:) }` — G7SensorKit layout plus `responseStatus = data[1]` (G7SensorKit rejected non-zero; DirectConnect keeps it and the manager ignores the value when non-zero, as xDrip does).
  - `struct DirectConnect_G7BackfillMessage: Equatable` (G7SensorKit layout, 9 bytes, `timestamp` = 24-bit LE at 0..<3).
  - `struct DirectConnect_G7ExtendedVersion: Equatable { sessionLength, warmupDuration: TimeInterval; algorithmVersion: UInt32; hardwareVersion: UInt8; maxLifetimeDays: UInt16; data: Data; init?(data:) }`
  - `struct DirectConnect_G7BatteryStatus: Equatable { status: UInt8; voltageA, voltageB, resistance, runtime, temperature: Int; init?(data:) }`
  - `struct DirectConnect_G7VersionInfo: Equatable { status: UInt8; firmwareVersion: String; buildVersion, versionCode: UInt32; serialNumber: UInt64; init?(data:) }`
  - `struct DirectConnect_AuthRequestRx { tokenHash: Data; challenge: Data; init?(data:) }` (≥17 bytes, opcode 0x03)
  - `struct DirectConnect_AuthStatusRx { authenticated: Bool; paired: Bool; init?(data:) }` (opcode 0x05, `authenticated = data[1]==1`, `paired = data[2] != 2`)
  - `enum DirectConnect_G7Requests { static let glucose = Data([0x4E]); static let extendedVersion = Data([0x52]); static let calibrationBounds = Data([0x32]); static var battery: Data { Data([0x22]).dcAppendingCRC() }; static var version: Data { Data([0x4A]).dcAppendingCRC() } }`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
import LoopKit
@testable import Loop

final class DirectConnect_G7MessagesTests: XCTestCase {
    func testGlucoseMessageParsesG7SensorKitVector() {
        let m = DirectConnect_G7GlucoseMessage(data: Data(dcHex: "4e00d5070000090000010500610006 01ffff0e".replacingOccurrences(of: " ", with: ""))!)!
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
        let m = DirectConnect_G7GlucoseMessage(data: Data(dcHex: "4e01d5070000090000010500610006 01ffff0e".replacingOccurrences(of: " ", with: ""))!)!
        XCTAssertEqual(m.responseStatus, 1)
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
        XCTAssertEqual(ten.sessionLength, 907200)  // 10.5 days
        XCTAssertEqual(ten.warmupDuration, 1620)
        XCTAssertEqual(ten.maxLifetimeDays, 12)
        let fifteen = DirectConnect_G7ExtendedVersion(data: Data(dcHex: "5200406f1400880e00010a04ff1100")!)!
        XCTAssertEqual(fifteen.sessionLength, 1339200) // 15.5 days
        XCTAssertEqual(fifteen.warmupDuration, 3720)
        XCTAssertEqual(fifteen.maxLifetimeDays, 17)
    }

    func testBatteryStatus() {
        let m = DirectConnect_G7BatteryStatus(data: Data(dcHex: "2200100e0a0eb40014f6")!)!
        XCTAssertEqual(m.voltageA, 0x0e10); XCTAssertEqual(m.voltageB, 0x0e0a)
        XCTAssertEqual(m.resistance, 180); XCTAssertEqual(m.runtime, 20); XCTAssertEqual(m.temperature, -10)
    }

    func testVersionInfo() {
        let m = DirectConnect_G7VersionInfo(data: Data(dcHex: "4a00020301040a000000140000000102030405 06".replacingOccurrences(of: " ", with: ""))!)!
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

    func testChunking() {
        let chunks = Data(repeating: 1, count: 45).dcChunked(into: 20)
        XCTAssertEqual(chunks.map(\.count), [20, 20, 5])
    }
}
```

- [ ] **Step 2: Run to verify failure** — Operator. Expected: FAIL, missing types.
- [ ] **Step 3: Implement** — port the listed sources with the renames above. Use explicit little-endian readers (`dcUInt16LE` etc.) instead of G7SensorKit's `to(_:)`/`toInt()` helpers. CRC: CCITT-XModem from xDrip `NSData+CRC.swift`, appended little-endian.
- [ ] **Step 4: Run to verify pass** — Operator.
- [ ] **Step 5: Commit** — `git commit -m "DirectConnect: G7 message parsers and byte helpers"`

---

### Task 3: Sensor model (G7 / ONE+ / Stelo)

**Files:**
- Create: `Loop/Managers/DirectConnect/DirectConnect_SensorModel.swift`
- Test: `LoopTests/DirectConnect/DirectConnect_SensorModelTests.swift`

**Interfaces:**
- Produces:
  - `enum DirectConnect_SensorType: String, CaseIterable, Codable { case g7, onePlus, stelo }` with `displayName`, `namePrefix` (`"DXCM"`, `"DX02"`, `"DX01"`), `static func from(peripheralName: String) -> DirectConnect_SensorType?`, `supportsFifteenDayOption: Bool` (g7 only).
  - `enum DirectConnect_SensorLifetime { static let gracePeriod: TimeInterval = 12h; static let tenDaySession = 10.5 days; static let fifteenDaySession = 15.5 days; static let defaultWarmup = 27 min; static func sessionLength(reported: TimeInterval?, type: DirectConnect_SensorType, userFifteenDay: Bool) -> TimeInterval }` — reported value wins if it equals one of the two known lengths; otherwise Stelo → 15.5 d, G7 with user switch → 15.5 d, else 10.5 d.
  - `func DirectConnect_shouldConnect(peripheralName: String?, followedName: String?, excludedName: String?, expectedType: DirectConnect_SensorType?) -> DirectConnect_ConnectDecision` with `enum DirectConnect_ConnectDecision { case makeActive, connect, ignore }`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Loop

final class DirectConnect_SensorModelTests: XCTestCase {
    func testTypeFromName() {
        XCTAssertEqual(DirectConnect_SensorType.from(peripheralName: "DXCMab"), .g7)
        XCTAssertEqual(DirectConnect_SensorType.from(peripheralName: "DX02cd"), .onePlus)
        XCTAssertEqual(DirectConnect_SensorType.from(peripheralName: "DX01ef"), .stelo)
        XCTAssertNil(DirectConnect_SensorType.from(peripheralName: "Dexcom12"))
    }

    func testSessionLengthPrefersReportedValue() {
        XCTAssertEqual(DirectConnect_SensorLifetime.sessionLength(reported: 1339200, type: .g7, userFifteenDay: false), 1339200)
        XCTAssertEqual(DirectConnect_SensorLifetime.sessionLength(reported: 907200, type: .stelo, userFifteenDay: false), 907200)
    }

    func testSessionLengthFallbacks() {
        XCTAssertEqual(DirectConnect_SensorLifetime.sessionLength(reported: nil, type: .g7, userFifteenDay: false), 907200)
        XCTAssertEqual(DirectConnect_SensorLifetime.sessionLength(reported: nil, type: .g7, userFifteenDay: true), 1339200)
        XCTAssertEqual(DirectConnect_SensorLifetime.sessionLength(reported: nil, type: .stelo, userFifteenDay: false), 1339200)
        XCTAssertEqual(DirectConnect_SensorLifetime.sessionLength(reported: nil, type: .onePlus, userFifteenDay: true), 907200)
        XCTAssertEqual(DirectConnect_SensorLifetime.sessionLength(reported: 12345, type: .g7, userFifteenDay: false), 907200)
    }

    func testFollowedSensorIsMadeActive() {
        XCTAssertEqual(DirectConnect_shouldConnect(peripheralName: "DXCMab", followedName: "DXCMab", excludedName: nil, expectedType: .g7), .makeActive)
    }

    func testScanConnectsMatchingTypeOnly() {
        XCTAssertEqual(DirectConnect_shouldConnect(peripheralName: "DXCMab", followedName: nil, excludedName: nil, expectedType: .g7), .connect)
        XCTAssertEqual(DirectConnect_shouldConnect(peripheralName: "DX01ab", followedName: nil, excludedName: nil, expectedType: .g7), .ignore)
    }

    func testScanSkipsPreviousSensorName() {
        XCTAssertEqual(DirectConnect_shouldConnect(peripheralName: "DXCMold", followedName: nil, excludedName: "DXCMold", expectedType: .g7), .ignore)
    }

    func testIgnoresOtherFollowedNamesAndUnnamed() {
        XCTAssertEqual(DirectConnect_shouldConnect(peripheralName: "DXCMzz", followedName: "DXCMab", excludedName: nil, expectedType: .g7), .ignore)
        XCTAssertEqual(DirectConnect_shouldConnect(peripheralName: nil, followedName: nil, excludedName: nil, expectedType: .g7), .ignore)
    }
}
```

- [ ] **Step 2–5:** run (fail) → implement → run (pass) → `git commit -m "DirectConnect: sensor type and lifetime model"`

---

### Task 4: C elliptic-curve layer and bridging header

**Files:**
- Create: `Loop/Managers/DirectConnect/Crypto/micro-ecc/` — copy `uECC.c`, `uECC.h`, `uECC_vli.h`, `types.h`, `curve-specific.inc`, `platform-specific.inc`, `asm_arm.inc`, `asm_arm_mult_square.inc`, `asm_arm_mult_square_umaal.inc`, `LICENSE.txt`, `README.md` verbatim from xDrip4iOS `xdrip/ThirdParty/micro-ecc/` (pinned revision 541b3a78).
- Create: `Loop/Managers/DirectConnect/Crypto/DirectConnect_ECC.h` / `.c` — xDrip4iOS `DexcomG7ECC.h/.c` with every `DexcomG7ECC` prefix renamed `DirectConnect_ECC`, include path changed to `micro-ecc/uECC.h`, `micro-ecc/uECC_vli.h`, `micro-ecc/uECC.c`.
- Create: `Loop/Managers/DirectConnect/DirectConnect-Bridging.h` containing `#import "Crypto/DirectConnect_ECC.h"`.
- Modify: `Loop.xcodeproj/project.pbxproj` — done in Task 14.

**Interfaces:**
- Produces (C, visible to Swift): `DirectConnect_ECCScalarSize = 32`, `DirectConnect_ECCPointSize = 64`, `DirectConnect_ECCGenerateKeyPair`, `DirectConnect_ECCIsValidPoint`, `DirectConnect_ECCPointAdd`, `DirectConnect_ECCPointSubtract`, `DirectConnect_ECCPointMultiply`, `DirectConnect_ECCGeneratorMultiply`, `DirectConnect_ECCScalarRandom`, `DirectConnect_ECCScalarMultiplyModN`, `DirectConnect_ECCScalarSubtractModN`, `DirectConnect_ECCScalarReduceModN`, `DirectConnect_ECCScalarFromBytes` — same signatures as xDrip.

- [ ] **Step 1:** Copy and rename (sed over the two files; diff against source to confirm only prefixes and include paths changed).
- [ ] **Step 2:** Tests for this layer live in Task 5 (they need Swift access through the bridging header).
- [ ] **Step 3: Commit** — `git commit -m "DirectConnect: vendored micro-ecc and P-256 point arithmetic"`

---

### Task 5: Swift crypto and Keychain key store

**Files:**
- Create: `Loop/Managers/DirectConnect/DirectConnect_G7Crypto.swift`
- Create: `Loop/Managers/DirectConnect/DirectConnect_KeyStore.swift`
- Test: `LoopTests/DirectConnect/DirectConnect_G7CryptoTests.swift`

Source to adapt: xDrip4iOS `DexcomG7AuthBridge.m` (math functions, constants), `AESCrypt.m` (AES-128-ECB, no padding), `DexcomG7ProofSigner.swift`.

**Interfaces:**
- Produces:
  - `enum DirectConnect_G7CryptoError: Error { case invalidChallenge, missingPairingCode, invalidPakePacket, validationFailed, ecc(String), signatureFailed, missingSharedKey }`
  - `enum DirectConnect_G7Crypto` (pure functions):
    - `static func aesECB(_ data: Data, key: Data) throws -> Data`
    - `static func challengeHash(_ challenge: Data, key: Data) throws -> Data` — AES(challenge+challenge)[0..<8]
    - `static func passwordScalar(code: String) throws -> Data` — 6-char codes get `"00"` ASCII prefix; then `ScalarFromBytes`
    - `static func generateKeyPair() throws -> (publicKey: Data, privateKey: Data)`
    - `static func makeZKPacket(privateKey: Data, publicKey: Data, base: Data?, party: Data) throws -> Data` (160 bytes)
    - `static func validateZKPacket(_ packet: DirectConnect_PakePacket, base: Data, party: Data) throws`
    - `static func pointAdd(_:_:) throws -> Data`, `pointSubtract`, `pointMultiply(_ point: Data, _ scalar: Data)`, `scalarMultiplyModN`
    - `static let generator: Data` (64 bytes), `static let clientParty = Data("client".utf8)`, `static let serverParty = Data("server".utf8)`
    - `static let certificatePartA: Data`, `certificatePartB: Data`, `proofSigningScalar: Data` — copied byte-exact from the xDrip hex constants (`G7KeksPartAHex`, `G7KeksPartBHex`, `G7KeksPartCRawScalarHex`) by a script, not retyped.
    - `static func proofSignature(challenge: Data) throws -> Data` — CryptoKit `P256.Signing.PrivateKey(rawRepresentation:)`, sign `SHA256.hash(data: challenge)`, return `.rawRepresentation` (64 bytes).
  - `struct DirectConnect_PakePacket { publicKey: Data; proofPoint: Data; proofScalar: Data; init(data: Data) throws }` — validates both points.
  - `final class DirectConnect_JPAKE` — holds round state: `init(pairingCode: String) throws`; `func handleRemote(phase: UInt8, payload: Data) throws -> (localPacket: Data, derivedKey: Data?)`. Phase 0/1 validate against generator + serverParty and return local round 1/2 packets; phase 2 validates round-3 against `pubA + pubB + remoteRound1.pub`, builds local round 3, derives `SHA256(keyPoint.x)[0..<16]`.
  - `protocol DirectConnect_KeyStoring { func key(sensor: String, slot: UInt8) -> Data?; func save(_ key: Data, sensor: String, slot: UInt8); func delete(sensor: String) }`
  - `final class DirectConnect_KeychainKeyStore: DirectConnect_KeyStoring` (service `com.loopkit.Loop.DirectConnect`, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` so background reconnects work while the phone is locked).
  - `final class DirectConnect_MemoryKeyStore: DirectConnect_KeyStoring` (tests).

- [ ] **Step 1: Write the failing test**

```swift
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
```

- [ ] **Step 2–5:** run (fail) → implement → run (pass) → `git commit -m "DirectConnect: G7 crypto, J-PAKE, and Keychain key store"`

**Checkpoint A:** Operator adds Tasks 1–5 files to the Xcode project (or waits for Task 14) and runs `DirectConnect_*Tests`. All must pass before Task 6.

---

### Task 6: Pairing state machine

**Files:**
- Create: `Loop/Managers/DirectConnect/DirectConnect_G7Pairing.swift`
- Test: `LoopTests/DirectConnect/DirectConnect_G7PairingTests.swift`

Source to adapt: xDrip4iOS `DexcomG7AuthSession.swift` (state machine, buffering, stage rules) and the control-packet builders in `DexcomG7AuthBridge.m` (`initialControlPacket`, `makeAuthRequest`, `certificateRequestForPhase`, `certificateStreamPacketsForPhase`, `makeProofOfPossessionChallengeRequest`).

**Interfaces:**
- Consumes: `DirectConnect_G7Crypto`, `DirectConnect_JPAKE`, `DirectConnect_KeyStoring`, `DirectConnect_AuthRequestRx`, `DirectConnect_AuthStatusRx`, `Data.dcChunked`.
- Produces:
  - `enum DirectConnect_AuthCharacteristic { case control, stream }`
  - `struct DirectConnect_AuthWrite: Equatable { let target: DirectConnect_AuthCharacteristic; let data: Data; let delay: TimeInterval }`
  - `enum DirectConnect_PairingEvent: Equatable { case writes([DirectConnect_AuthWrite]); case authenticated; case rejectedSavedKey; case needsCleanReconnect; case failed(String) }`
  - `final class DirectConnect_G7Pairing` with
    - `init(sensorName: String, pairingCode: String?, slot: UInt8 = 0x02, keyStore: DirectConnect_KeyStoring, tokenSource: @escaping () -> Data = { random 8 bytes })`
    - `var hasSavedKey: Bool`
    - `func start() -> DirectConnect_PairingEvent` — call when both auth characteristics are notifying. Saved key → `writes([control 02 <token8> <slot>])`; else `writes([control 0A 00])` and creates `DirectConnect_JPAKE`.
    - `func receiveControl(_ data: Data) -> [DirectConnect_PairingEvent]`
    - `func receiveStream(_ data: Data) -> [DirectConnect_PairingEvent]`
    - `func resetForConnection()`
  - Stream writes use 0.04 s spacing (`delay = 0.04 * index`), control after stream at `0.04 * (count + 1)`, exactly as xDrip `writeExchange`.
  - Key saved to `keyStore` only on `06 01` after proof stage, or on `08 01` in the legacy bond path.

- [ ] **Step 1: Write the failing test**

```swift
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

    func testSavedKeyStartsShortAuth() {
        let store = DirectConnect_MemoryKeyStore()
        store.save(key, sensor: "DXCMab", slot: 2)
        let p = DirectConnect_G7Pairing(sensorName: "DXCMab", pairingCode: nil, keyStore: store, tokenSource: { self.token })
        XCTAssertEqual(p.start(), .writes([DirectConnect_AuthWrite(target: .control, data: Data([0x02]) + token + Data([0x02]), delay: 0)]))
    }

    func testShortAuthChallengeResponseThenAuthenticated() throws {
        let store = DirectConnect_MemoryKeyStore()
        store.save(key, sensor: "DXCMab", slot: 2)
        let p = DirectConnect_G7Pairing(sensorName: "DXCMab", pairingCode: nil, keyStore: store, tokenSource: { self.token })
        _ = p.start()
        let challenge = Data(dcHex: "a1a2a3a4a5a6a7a8")!
        let tokenHash = try DirectConnect_G7Crypto.challengeHash(token, key: key)
        let events = p.receiveControl(Data([0x03]) + tokenHash + challenge)
        XCTAssertEqual(controlWrites(events), [Data([0x04]) + (try DirectConnect_G7Crypto.challengeHash(challenge, key: key))])
        XCTAssertEqual(p.receiveControl(Data([0x05, 0x01, 0x01])), [.authenticated])
    }

    func testRejectedSavedKeyStopsWithoutClearingKey() {
        let store = DirectConnect_MemoryKeyStore()
        store.save(key, sensor: "DXCMab", slot: 2)
        let p = DirectConnect_G7Pairing(sensorName: "DXCMab", pairingCode: nil, keyStore: store, tokenSource: { self.token })
        _ = p.start()
        XCTAssertEqual(p.receiveControl(Data([0x05, 0x00, 0x02])), [.rejectedSavedKey])
        XCTAssertEqual(store.key(sensor: "DXCMab", slot: 2), key)
    }

    func testAuthenticatedButUnpairedClearsKeyAndReconnects() {
        let store = DirectConnect_MemoryKeyStore()
        store.save(key, sensor: "DXCMab", slot: 2)
        let p = DirectConnect_G7Pairing(sensorName: "DXCMab", pairingCode: nil, keyStore: store, tokenSource: { self.token })
        _ = p.start()
        XCTAssertEqual(p.receiveControl(Data([0x05, 0x01, 0x02])), [.needsCleanReconnect])
        XCTAssertNil(store.key(sensor: "DXCMab", slot: 2))
    }

    func testNoSavedKeyStartsJPAKE() {
        let p = DirectConnect_G7Pairing(sensorName: "DXCMab", pairingCode: "1234", keyStore: DirectConnect_MemoryKeyStore())
        XCTAssertEqual(p.start(), .writes([DirectConnect_AuthWrite(target: .control, data: Data([0x0A, 0x00]), delay: 0)]))
    }

    func testNoSavedKeyAndNoCodeFails() {
        let p = DirectConnect_G7Pairing(sensorName: "DXCMab", pairingCode: nil, keyStore: DirectConnect_MemoryKeyStore())
        guard case .failed = p.start() else { return XCTFail("expected failure") }
    }

    func testWrongCodeRejectionDoesNotPersistKey() {
        let store = DirectConnect_MemoryKeyStore()
        let p = DirectConnect_G7Pairing(sensorName: "DXCMab", pairingCode: "1234", keyStore: store)
        _ = p.start()
        // A rejected J-PAKE control status from the sensor.
        let events = p.receiveControl(Data([0x0A, 0x01, 0x00]))
        XCTAssertTrue(events.contains { if case .failed = $0 { return true }; return false })
        XCTAssertNil(store.key(sensor: "DXCMab", slot: 2))
    }

    func testPakeStreamAndControlCanArriveInEitherOrder() {
        let p = DirectConnect_G7Pairing(sensorName: "DXCMab", pairingCode: "1234", keyStore: DirectConnect_MemoryKeyStore())
        _ = p.start()
        // Off-curve payload: whichever order the halves arrive in, the phase is processed exactly once and fails validation.
        let streamFirst = p.receiveStream(Data(repeating: 0x01, count: 160))
        XCTAssertTrue(streamFirst.isEmpty)
        let events = p.receiveControl(Data([0x0A, 0x00, 0x00]))
        XCTAssertEqual(events.count, 1)
        guard case .failed = events[0] else { return XCTFail("expected validation failure") }
    }

    func testOwnershipKeepAliveClassification() {
        XCTAssertEqual(DirectConnect_G7Pairing.keepAliveAction(Data([0x06, 0x01])), .completeOwnership)
        XCTAssertEqual(DirectConnect_G7Pairing.keepAliveAction(Data([0x06, 0x00])), .requestLegacyBond)
        XCTAssertEqual(DirectConnect_G7Pairing.keepAliveAction(Data([0x06, 0x05])), .ignore)
    }

    func testDerivedKeyNotPersistedUntilOwnershipConfirmed() {
        let store = DirectConnect_MemoryKeyStore()
        let p = DirectConnect_G7Pairing(sensorName: "DXCMab", pairingCode: "1234", keyStore: store)
        p.testHook_setCandidateKey(key, stage: .proofOfPossession)
        XCTAssertNil(store.key(sensor: "DXCMab", slot: 2))
        _ = p.receiveControl(Data([0x0D, 0x00]))       // proof accepted → we send 06 19
        XCTAssertNil(store.key(sensor: "DXCMab", slot: 2))
        XCTAssertEqual(p.receiveControl(Data([0x06, 0x01])), [.authenticated])
        XCTAssertEqual(store.key(sensor: "DXCMab", slot: 2), key)
    }

    func testCertificateRequestEncodesLittleEndianLength() {
        let req = DirectConnect_G7Pairing.certificateRequest(phase: 0)
        XCTAssertEqual(req.prefix(2), Data([0x0B, 0x00]))
        XCTAssertEqual(req.dcUInt32LE(at: 2), UInt32(DirectConnect_G7Crypto.certificatePartA.count))
        XCTAssertEqual(DirectConnect_G7Pairing.certificateRequest(phase: 2), Data([0x0B, 0x02, 0, 0, 0, 0]))
    }
}
```

(`testHook_setCandidateKey(_:stage:)` is an `internal` method marked `// Test seam` that sets the J-PAKE-derived candidate key and stage, so the ownership-confirmation rule can be tested without a simulated sensor.)

- [ ] **Step 2–5:** run (fail) → implement → run (pass) → `git commit -m "DirectConnect: G7 pairing state machine"`

---

### Task 7: Calibration logic

**Files:**
- Create: `Loop/Managers/DirectConnect/DirectConnect_G7Calibration.swift`
- Test: `LoopTests/DirectConnect/DirectConnect_G7CalibrationTests.swift`

Source to adapt: xDrip4iOS `DexcomG7CalibrationMessages.swift` (all types), calibration flow in `CGMG7Transmitter.swift` (`sendCalibrationOrBoundsIfReady`, `handleCalibrationCommandResponse`, `handleCalibrationBounds`, `calibrationIsValid`), and test cases from `xDrip Tests/DexcomG7CalibrationTests.swift`.

**Interfaces:**
- Produces:
  - `struct DirectConnect_CalibrationCommand { glucose: UInt16; transmitterTime: UInt32; var data: Data }` (opcode 0x34, LE fields, CRC)
  - `DirectConnect_CalibrationRejectionReason`, `DirectConnect_CalibrationCommandResponse`, `DirectConnect_CalibrationBounds`, `DirectConnect_CalibrationProcessingState` (renamed copies)
  - `struct DirectConnect_ClockReference { transmitterTime: UInt32; referenceDate: Date; func transmitterTime(for: Date) -> UInt32? }`
  - `enum DirectConnect_CalibrationStatus: Equatable { case none, queued, sent, processing, completed, rejected(String), notPermitted }`
  - `struct DirectConnect_PendingCalibration: Codable, Equatable { id: UUID; glucose: Double; date: Date }`
  - `struct DirectConnect_CalibrationQueue` (value type, persisted inside manager state): `var pending: DirectConnect_PendingCalibration?`, `var awaitingBounds: DirectConnect_PendingCalibration?`, `var lastCommandTime: UInt32?`, `var status`; `mutating func enqueue(glucose:date:) -> Bool` (40–400 mg/dL, not in the future, not older than 5 min — `maxUnsentAge = 300`); `mutating func nextCommand(clock: DirectConnect_ClockReference?, now: Date) -> Data?`; `mutating func handleCommandResponse(_ data: Data)`; `mutating func handleBounds(_ data: Data)`; `mutating func connectionDidEnd()` (in-flight command returns to `pending`).

- [ ] **Step 1: Write the failing test** — port every test from xDrip `DexcomG7CalibrationTests.swift` with types renamed, then add:

```swift
func testEnqueueRejectsOutOfRangeAndStale() {
    var q = DirectConnect_CalibrationQueue()
    XCTAssertFalse(q.enqueue(glucose: 35, date: Date()))
    XCTAssertFalse(q.enqueue(glucose: 120, date: Date().addingTimeInterval(-600)))
    XCTAssertTrue(q.enqueue(glucose: 120, date: Date()))
    XCTAssertEqual(q.status, .queued)
}

func testCommandUsesClockReference() {
    var q = DirectConnect_CalibrationQueue()
    let now = Date()
    XCTAssertTrue(q.enqueue(glucose: 120, date: now))
    let clock = DirectConnect_ClockReference(transmitterTime: 1000, referenceDate: now.addingTimeInterval(-10))
    let data = q.nextCommand(clock: clock, now: now)!
    XCTAssertEqual(data[0], 0x34)
    XCTAssertEqual(data.dcUInt16LE(at: 1), 120)
    XCTAssertEqual(data.dcUInt32LE(at: 3), 1010)
    XCTAssertEqual(q.status, .sent)
}

func testNoClockMeansNoCommand() {
    var q = DirectConnect_CalibrationQueue()
    XCTAssertTrue(q.enqueue(glucose: 120, date: Date()))
    XCTAssertNil(q.nextCommand(clock: nil, now: Date()))
    XCTAssertEqual(q.status, .queued)
}

func testInterruptedCommandIsRequeued() {
    var q = DirectConnect_CalibrationQueue()
    let now = Date()
    XCTAssertTrue(q.enqueue(glucose: 120, date: now))
    _ = q.nextCommand(clock: DirectConnect_ClockReference(transmitterTime: 1000, referenceDate: now), now: now)
    q.connectionDidEnd()
    XCTAssertEqual(q.status, .queued)
    XCTAssertNotNil(q.pending)
}

func testRejectedResponseShowsReason() {
    var q = DirectConnect_CalibrationQueue()
    let now = Date()
    XCTAssertTrue(q.enqueue(glucose: 120, date: now))
    _ = q.nextCommand(clock: DirectConnect_ClockReference(transmitterTime: 1000, referenceDate: now), now: now)
    q.handleCommandResponse(Data([0x34, 0x00, 0x02, 0x01]))  // rejected: outside range
    XCTAssertEqual(q.status, .rejected("outside range"))
}
```

- [ ] **Step 2–5:** run (fail) → implement → run (pass) → `git commit -m "DirectConnect: G7 calibration queue and messages"`

---

### Task 8: Glucose alarm evaluator

**Files:**
- Create: `Loop/Managers/DirectConnect/DirectConnect_GlucoseAlarms.swift`
- Test: `LoopTests/DirectConnect/DirectConnect_GlucoseAlarmsTests.swift`

**Interfaces:**
- Consumes: `DirectConnect_AlarmSettings`, `DirectConnect_AlarmKind`.
- Produces:
  - `struct DirectConnect_AlarmReading { date: Date; mgdl: Double; trendRate: Double? }`
  - `struct DirectConnect_AlarmState: Codable, Equatable { var lastFired: [String: Date] }` (key = `DirectConnect_AlarmKind.rawValue`; persisted in manager state)
  - `enum DirectConnect_AlarmAction: Equatable { case issue(DirectConnect_AlarmKind, valueText: String); case retract(DirectConnect_AlarmKind) }`
  - `enum DirectConnect_GlucoseAlarms { static func evaluate(reading: DirectConnect_AlarmReading, settings: DirectConnect_AlarmSettings, state: inout DirectConnect_AlarmState) -> [DirectConnect_AlarmAction]; static func evaluateSignal(lastReading: Date?, now: Date, settings:, state: inout) -> [DirectConnect_AlarmAction]; static func evaluateLifetime(expiresAt: Date?, endedOrFailed: Bool, now: Date, settings:, state: inout) -> [DirectConnect_AlarmAction] }`
  - Rules: Urgent Low takes precedence over Low (when urgent low fires, low is retracted). An alarm issues when its condition is true and it has not fired, or its repeat interval has passed since `lastFired`. When the condition becomes false and `lastFired` exists, emit `retract` and remove the entry. Rate alarms: once per episode (re-arm after the rate returns inside the threshold). Signal loss: once per gap. Expiring: once at ≤24 h and once at ≤2 h (state keys `sensorExpiring24`, `sensorExpiring2`). Disabled alarms never issue and retract if active.
  - `static func alert(for action: DirectConnect_AlarmAction, managerIdentifier: String, unit: HKUnit) -> LoopKit.Alert?` — builds `Alert` with identifier `Alert.Identifier(managerIdentifier: managerIdentifier, alertIdentifier: kind.rawValue)`, trigger `.immediate`, interruption level per spec table, sound `.vibrate` for `.active`, `.sound(name: "DirectConnect_Alarm.caf")` is NOT used (no custom sound file); use `nil` sound so Loop's default plays.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Loop

final class DirectConnect_GlucoseAlarmsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func r(_ min: Double, _ mgdl: Double, rate: Double? = nil) -> DirectConnect_AlarmReading {
        DirectConnect_AlarmReading(date: t0.addingTimeInterval(min * 60), mgdl: mgdl, trendRate: rate)
    }
    private func kinds(_ a: [DirectConnect_AlarmAction]) -> [String] {
        a.map { switch $0 { case let .issue(k, _): return "+\(k.rawValue)"; case let .retract(k): return "-\(k.rawValue)" } }
    }

    func testLowIssuesOnce() {
        var s = DirectConnect_AlarmState(lastFired: [:])
        XCTAssertEqual(kinds(DirectConnect_GlucoseAlarms.evaluate(reading: r(0, 68), settings: .defaults, state: &s)), ["+low"])
        XCTAssertEqual(kinds(DirectConnect_GlucoseAlarms.evaluate(reading: r(5, 66), settings: .defaults, state: &s)), [])
    }

    func testLowRepeatsOnlyAfterInterval() {
        var s = DirectConnect_AlarmState(lastFired: [:])
        _ = DirectConnect_GlucoseAlarms.evaluate(reading: r(0, 68), settings: .defaults, state: &s)
        XCTAssertEqual(kinds(DirectConnect_GlucoseAlarms.evaluate(reading: r(10, 69), settings: .defaults, state: &s)), [])
        XCTAssertEqual(kinds(DirectConnect_GlucoseAlarms.evaluate(reading: r(15, 69), settings: .defaults, state: &s)), ["+low"])
    }

    func testLowRetractsWhenBackInRange() {
        var s = DirectConnect_AlarmState(lastFired: [:])
        _ = DirectConnect_GlucoseAlarms.evaluate(reading: r(0, 68), settings: .defaults, state: &s)
        XCTAssertEqual(kinds(DirectConnect_GlucoseAlarms.evaluate(reading: r(5, 75), settings: .defaults, state: &s)), ["-low"])
        XCTAssertTrue(s.lastFired.isEmpty)
    }

    func testUrgentLowReplacesLow() {
        var s = DirectConnect_AlarmState(lastFired: [:])
        _ = DirectConnect_GlucoseAlarms.evaluate(reading: r(0, 68), settings: .defaults, state: &s)
        XCTAssertEqual(Set(kinds(DirectConnect_GlucoseAlarms.evaluate(reading: r(5, 54), settings: .defaults, state: &s))), ["+urgentLow", "-low"])
    }

    func testUrgentLowRepeatsEveryFiveMinutes() {
        var s = DirectConnect_AlarmState(lastFired: [:])
        _ = DirectConnect_GlucoseAlarms.evaluate(reading: r(0, 50), settings: .defaults, state: &s)
        XCTAssertEqual(kinds(DirectConnect_GlucoseAlarms.evaluate(reading: r(5, 50), settings: .defaults, state: &s)), ["+urgentLow"])
    }

    func testHigh() {
        var s = DirectConnect_AlarmState(lastFired: [:])
        XCTAssertEqual(kinds(DirectConnect_GlucoseAlarms.evaluate(reading: r(0, 260), settings: .defaults, state: &s)), ["+high"])
        XCTAssertEqual(kinds(DirectConnect_GlucoseAlarms.evaluate(reading: r(30, 270), settings: .defaults, state: &s)), [])
        XCTAssertEqual(kinds(DirectConnect_GlucoseAlarms.evaluate(reading: r(60, 270), settings: .defaults, state: &s)), ["+high"])
    }

    func testDisabledAlarmNeverIssues() {
        var settings = DirectConnect_AlarmSettings.defaults
        settings.highEnabled = false
        var s = DirectConnect_AlarmState(lastFired: [:])
        XCTAssertEqual(kinds(DirectConnect_GlucoseAlarms.evaluate(reading: r(0, 300), settings: settings, state: &s)), [])
    }

    func testFallingFastOncePerEpisode() {
        var s = DirectConnect_AlarmState(lastFired: [:])
        XCTAssertEqual(kinds(DirectConnect_GlucoseAlarms.evaluate(reading: r(0, 150, rate: -3.5), settings: .defaults, state: &s)), ["+fallingFast"])
        XCTAssertEqual(kinds(DirectConnect_GlucoseAlarms.evaluate(reading: r(5, 130, rate: -3.5), settings: .defaults, state: &s)), [])
        XCTAssertEqual(kinds(DirectConnect_GlucoseAlarms.evaluate(reading: r(10, 125, rate: -1), settings: .defaults, state: &s)), ["-fallingFast"])
        XCTAssertEqual(kinds(DirectConnect_GlucoseAlarms.evaluate(reading: r(15, 110, rate: -3.2), settings: .defaults, state: &s)), ["+fallingFast"])
    }

    func testRisingFastOffByDefault() {
        var s = DirectConnect_AlarmState(lastFired: [:])
        XCTAssertEqual(kinds(DirectConnect_GlucoseAlarms.evaluate(reading: r(0, 150, rate: 4), settings: .defaults, state: &s)), [])
    }

    func testSignalLossOncePerGap() {
        var s = DirectConnect_AlarmState(lastFired: [:])
        XCTAssertEqual(kinds(DirectConnect_GlucoseAlarms.evaluateSignal(lastReading: t0, now: t0.addingTimeInterval(19 * 60), settings: .defaults, state: &s)), [])
        XCTAssertEqual(kinds(DirectConnect_GlucoseAlarms.evaluateSignal(lastReading: t0, now: t0.addingTimeInterval(21 * 60), settings: .defaults, state: &s)), ["+signalLoss"])
        XCTAssertEqual(kinds(DirectConnect_GlucoseAlarms.evaluateSignal(lastReading: t0, now: t0.addingTimeInterval(40 * 60), settings: .defaults, state: &s)), [])
        XCTAssertEqual(kinds(DirectConnect_GlucoseAlarms.evaluateSignal(lastReading: t0.addingTimeInterval(41 * 60), now: t0.addingTimeInterval(41 * 60), settings: .defaults, state: &s)), ["-signalLoss"])
    }

    func testSensorExpiringFiresAt24hAnd2h() {
        var s = DirectConnect_AlarmState(lastFired: [:])
        let exp = t0.addingTimeInterval(30 * 3600)
        XCTAssertEqual(kinds(DirectConnect_GlucoseAlarms.evaluateLifetime(expiresAt: exp, endedOrFailed: false, now: t0, settings: .defaults, state: &s)), [])
        XCTAssertEqual(kinds(DirectConnect_GlucoseAlarms.evaluateLifetime(expiresAt: exp, endedOrFailed: false, now: t0.addingTimeInterval(7 * 3600), settings: .defaults, state: &s)), ["+sensorExpiring"])
        XCTAssertEqual(kinds(DirectConnect_GlucoseAlarms.evaluateLifetime(expiresAt: exp, endedOrFailed: false, now: t0.addingTimeInterval(8 * 3600), settings: .defaults, state: &s)), [])
        XCTAssertEqual(kinds(DirectConnect_GlucoseAlarms.evaluateLifetime(expiresAt: exp, endedOrFailed: false, now: t0.addingTimeInterval(28.5 * 3600), settings: .defaults, state: &s)), ["+sensorExpiring"])
    }
}
```

- [ ] **Step 2–5:** run (fail) → implement → run (pass) → `git commit -m "DirectConnect: glucose alarm evaluator"`

**Checkpoint B:** Operator runs all `DirectConnect_*Tests`. All pass before Task 9.

---

### Task 9: Bluetooth layer

**Files:**
- Create: `Loop/Managers/DirectConnect/DirectConnect_BluetoothManager.swift` (from G7SensorKit `G7BluetoothManager.swift`)
- Create: `Loop/Managers/DirectConnect/DirectConnect_PeripheralManager.swift` (from G7SensorKit `G7PeripheralManager.swift`, `CBPeripheral.swift`, `BluetoothServices.swift`)

**Changes from the G7SensorKit source:**
- Rename all types with `DirectConnect_` prefix; `PeripheralConnectionCommand` → `DirectConnect_ConnectDecision` (from Task 3).
- Restore identifier `com.loopkit.Loop.DirectConnect`; queue labels `com.loopkit.Loop.DirectConnect.*`.
- Characteristic enum adds `authStream = "F8083538-849E-531C-C594-30F1F86A4EA5"`; configuration discovers `authentication, control, backfill, authStream`.
- Delegate gains `didReceiveAuthStream response: Data` and `didUpdateNotificationState characteristic: DirectConnect_CharacteristicUUID, enabled: Bool`.
- `DirectConnect_PeripheralManager` gains `func write(_ data: Data, to: DirectConnect_CharacteristicUUID, withResponse: Bool) throws` (for `.withoutResponse` it calls `peripheral.writeValue` with no condition) and `func readRSSI()`.
- Notification-state updates that arrive with no pending command are forwarded to the delegate (the pairing machine waits for stream-then-control readiness).

- [ ] **Step 1:** Port with the listed changes.
- [ ] **Step 2:** No unit tests (CoreBluetooth). Covered by device testing.
- [ ] **Step 3: Commit** — `git commit -m "DirectConnect: Bluetooth central and peripheral managers"`

---

### Task 10: Connection orchestrator

**Files:**
- Create: `Loop/Managers/DirectConnect/DirectConnect_G7Sensor.swift`

**Interfaces:**
- Consumes: Tasks 2, 3, 5, 6, 7, 9.
- Produces:
  - `protocol DirectConnect_G7SensorDelegate: AnyObject` — `sensorDidConnect(_:name:)`, `sensorDisconnected(_:)`, `sensor(_:didRead: DirectConnect_G7GlucoseMessage, receivedAt: Date)`, `sensor(_:didReadBackfill: [DirectConnect_G7BackfillMessage])`, `sensor(_:didDiscoverNewSensor name: String, activatedAt: Date) -> Bool`, `sensor(_:didReceive: DirectConnect_G7ExtendedVersion)`, `sensor(_:didReceive: DirectConnect_G7BatteryStatus)`, `sensor(_:didReceive: DirectConnect_G7VersionInfo)`, `sensor(_:pairingDidFail reason: DirectConnect_PairingFailure)`, `sensorDidAuthenticate(_:)`, `sensor(_:calibrationStatusDidChange: DirectConnect_CalibrationStatus)`, `sensor(_:logComms: String)`, `sensor(_:didReadRSSI: Int)`, `sensorConnectionStatusDidUpdate(_:)`.
  - `enum DirectConnect_PairingFailure: Equatable { case wrongCode, keyRejected, protocolError(String) }`
  - `final class DirectConnect_G7Sensor` — `init(sensorName: String?, sensorType: DirectConnect_SensorType, pairingCode: String?, excludedName: String?, keyStore: DirectConnect_KeyStoring)`; `scanForNewSensor(type:pairingCode:excludedName:)`; `resumeScanning()`; `stopScanning()`; `enqueueCalibration(glucose:date:) -> Bool`; `var needsVersionInfo`, `needsFirmwareInfo`, `batteryLastRead: Date?`; `var isScanning`, `isConnected`.
- Per-connection sequence (from xDrip `CGMG7Transmitter` primary path): on ready → enable `authStream` notify → on its confirmation enable `authentication` notify → on its confirmation `pairing.start()` → execute pairing writes with their delays on the peripheral queue → on `.authenticated` enable `control` notify → on its confirmation write `0x4E` once → on glucose (status 0): set clock reference, enable `backfill` notify, then exactly one extra in priority order: calibration command/bounds → extended version (if unknown) → version info (if unknown) → battery (if ≥ 2 h). `0x59` flushes backfill. Disconnect: flush backfill, `calibration.connectionDidEnd()`, `pairing.resetForConnection()`.
- `.rejectedSavedKey` → stop reconnecting to this sensor (`authenticationBlocked = true`), report `.keyRejected`. `.needsCleanReconnect` → disconnect; next wake does full pairing. Pairing failure during J-PAKE validation → `.wrongCode`.

- [ ] **Step 1:** Implement.
- [ ] **Step 2: Commit** — `git commit -m "DirectConnect: G7 connection orchestrator"`

---

### Task 11: CGM manager and persisted state

**Files:**
- Create: `Loop/Managers/DirectConnect/DirectConnect_G7State.swift`
- Create: `Loop/Managers/DirectConnect/DirectConnect_G7CGMManager.swift`
- Create: `Loop/Managers/DirectConnect/DirectConnect_Diagnostics.swift`
- Test: `LoopTests/DirectConnect/DirectConnect_StateTests.swift`

Source to adapt: G7SensorKit `G7CGMManager.swift` and `G7CGMManagerState.swift` (state locking, delegate notification, sync identifiers, suspected-session-end grace period, backfill → `NewGlucoseSample`, `PersistedCgmEvent` sensor start).

**Interfaces:**
- Produces:
  - `struct DirectConnect_G7State: RawRepresentable, Equatable` — fields: `sensorID: String?`, `sensorType: DirectConnect_SensorType`, `pairingCode: String?`, `previousSensorID: String?`, `useFifteenDay: Bool`, `activatedAt: Date?`, `extendedVersion: DirectConnect_G7ExtendedVersion?`, `latestReading: DirectConnect_G7GlucoseMessage?`, `latestReadingTimestamp: Date?`, `latestConnect: Date?`, `uploadReadings: Bool = true`, `suspectedSessionEndAt: Date?`, `battery: DirectConnect_G7BatteryStatus?`, `batteryReadAt: Date?`, `versionInfo: DirectConnect_G7VersionInfo?`, `calibration: DirectConnect_CalibrationQueue`, `alarmState: DirectConnect_AlarmState`, `pairingFailure: String?`, `recentReadings: [Double]` (last 6 values, for the identical-value rule).
  - `final class DirectConnect_G7CGMManager: CGMManager` — `static let pluginIdentifier = "PowerPackDirectConnectG7"`, `static let localizedTitle = "Dexcom G7 / ONE+ / Stelo (DirectConnect)"`, `localizedTitle` instance, `providesBLEHeartbeat = true`, `managedDataInterval = .hours(3)`, `init()`, `init?(rawState:)`, `rawState`, `func configure(type: DirectConnect_SensorType, pairingCode: String, useFifteenDay: Bool)`, `func scanForNewSensor()`, `func calibrate(glucose: Double) -> Bool`, `func setUseFifteenDay(_:)`, `var lifecycleState: DirectConnect_LifecycleState`, `var lifetime`, `sensorExpiresAt`, `sensorEndsAt`, `warmupDuration`, `addStateObserver`/`removeStateObserver`, `func deleteCGM(completion:)` (clears Keychain key, sets `DirectConnect_FeatureFlags.isActiveCGM = false`, calls `notifyDelegateOfDeletion`).
  - Reading rules (spec §6): drop if `responseStatus != 0`, warmup, past `sensorEndsAt`, not `hasReliableGlucose`, glucose outside 40–400 after clamping is shown as below/above range (same as G7SensorKit), or last 6 values identical (`recentReadings`).
  - On each delivered reading: run `DirectConnect_GlucoseAlarms.evaluate`, `evaluateLifetime`; issue/retract via `delegate.issueAlert` / `retractAlert`. A timer every 60 s on the manager runs `evaluateSignal`.
  - `DirectConnect_Diagnostics`: ring buffer of the last 500 log lines (timestamp + text), `func export() -> String`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import Loop

final class DirectConnect_StateTests: XCTestCase {
    func testRawStateRoundTrip() {
        var s = DirectConnect_G7State()
        s.sensorID = "DXCMab"; s.sensorType = .stelo; s.pairingCode = "1234"; s.useFifteenDay = true
        s.activatedAt = Date(timeIntervalSince1970: 1_800_000_000)
        s.extendedVersion = DirectConnect_G7ExtendedVersion(data: Data(dcHex: "5200406f1400880e00010a04ff1100")!)
        s.latestReading = DirectConnect_G7GlucoseMessage(data: Data(dcHex: "4e00d507000009000001050061000601ffff0e")!)
        s.uploadReadings = false
        s.recentReadings = [100, 101]
        XCTAssertTrue(s.calibration.enqueue(glucose: 120, date: Date()))
        s.alarmState.lastFired["low"] = Date(timeIntervalSince1970: 1_800_000_100)
        XCTAssertEqual(DirectConnect_G7State(rawValue: s.rawValue), s)
    }

    func testEmptyRawStateUsesDefaults() {
        let s = DirectConnect_G7State(rawValue: [:])
        XCTAssertNil(s.sensorID)
        XCTAssertEqual(s.sensorType, .g7)
        XCTAssertTrue(s.uploadReadings)
        XCTAssertFalse(s.useFifteenDay)
    }
}
```

- [ ] **Step 2–5:** run (fail) → implement → run (pass) → `git commit -m "DirectConnect: CGM manager, state, and diagnostics log"`

---

### Task 12: CGM UI (setup, status, calibration, diagnostics)

**Files:**
- Create: `Loop/Views/DirectConnect/DirectConnect_CGMManager+UI.swift` (from G7SensorKitUI `G7CGMManager+UI.swift`: `CGMManagerUI` conformance, status highlight/badge/lifecycle progress; `smallImage` = SF Symbol `sensor.tag.radiowaves.forward.fill` rendered to `UIImage`)
- Create: `Loop/Views/DirectConnect/DirectConnect_UICoordinator.swift` (from `G7UICoordinator.swift`)
- Create: `Loop/Views/DirectConnect/DirectConnect_SetupView.swift` — sensor type picker (G7 / ONE+ / Stelo), 4-digit code field (`.numberPad`, accepts exactly 4 digits; 6 digits also accepted), "15-day sensor" toggle shown only for G7, "PowerPack Exclusive" label, Continue → `configure(...)` then `scanForNewSensor()`, shows "Searching…" / "Pairing…" / "Connected" from state observer, and the wrong-code message from `pairingFailure`.
- Create: `Loop/Views/DirectConnect/DirectConnect_SensorStatusView.swift` + `DirectConnect_SensorStatusViewModel.swift` (from `G7SettingsView.swift` / `G7SettingsViewModel.swift` / `G7ProgressBarState.swift`) — adds battery, firmware, sensor type, 15-day toggle (G7 only), "Calibrate" link, "Diagnostics" link, "Add New Sensor" (re-enter code), "Delete CGM".
- Create: `Loop/Views/DirectConnect/DirectConnect_CalibrationView.swift` — glucose entry in display unit, converts to mg/dL, calls `calibrate(glucose:)`, shows `calibration.status`.
- Create: `Loop/Views/DirectConnect/DirectConnect_DiagnosticsView.swift` — sensor name, type, firmware, build, RSSI, auth state (saved key yes/no), last connect, last reading, session length, log viewer, Share button exporting `DirectConnect_Diagnostics.export()`.

- [ ] **Step 1:** Implement (SwiftUI, LoopKitUI components `DismissibleHostingController`, `actionButtonStyle`, `LargeButton` as in neighboring files).
- [ ] **Step 2: Commit** — `git commit -m "DirectConnect: CGM setup, status, calibration, and diagnostics screens"`

---

### Task 13: Settings and Loop integration

**Files:**
- Create: `Loop/Views/DirectConnect/DirectConnect_SettingsView.swift` — master toggle with "PowerPack Exclusive" caption; toggle disabled with explanatory text when `DirectConnect_FeatureFlags.isActiveCGM`; link to Alarms; short explanation of what DirectConnect does and that the Dexcom app is not needed.
- Create: `Loop/Views/DirectConnect/DirectConnect_AlarmSettingsView.swift` — one section per alarm: on/off, threshold stepper/slider within range (display unit aware), repeat-interval picker; Urgent Low off → confirmation alert "Loop will not warn you about urgent low glucose."; saves via `DirectConnect_AlarmSettings.save(to: .standard)` on every change (normalized).
- Modify: `Loop/Managers/CGMManager.swift` — anchor inserts:

```swift
let staticCGMManagersByIdentifier: [String: CGMManager.Type] = [
    MockCGMManager.pluginIdentifier: MockCGMManager.self,
    // DirectConnect (PowerPack) — registered always so a configured CGM restores even if the flag is later off
    DirectConnect_G7CGMManager.pluginIdentifier: DirectConnect_G7CGMManager.self
]

var availableStaticCGMManagers: [CGMManagerDescriptor] {
    // DirectConnect (PowerPack) — listed only when its feature flag is on
    let directConnect: [CGMManagerDescriptor] = DirectConnect_FeatureFlags.isEnabled
        ? [CGMManagerDescriptor(identifier: DirectConnect_G7CGMManager.pluginIdentifier, localizedTitle: DirectConnect_G7CGMManager.localizedTitle)]
        : []
    if FeatureFlags.allowSimulators {
        return [
            CGMManagerDescriptor(identifier: MockCGMManager.pluginIdentifier, localizedTitle: MockCGMManager.localizedTitle)
        ] + directConnect
    } else {
        return directConnect
    }
}
```

- Modify: `Loop/Views/SettingsView.swift` — in `powerPackSection`, insert `directConnectSettingsRow` with `.listRowBackground(PowerPackGroupBorder(position: .middle))` after `bolusProSettingsRow`; add the row property next to the other PowerPack rows:

```swift
    // DirectConnect — single settings insertion point
    private var directConnectSettingsRow: some View {
        NavigationLink(destination: DirectConnect_SettingsView()) {
            LargeButton(action: {},
                        includeArrow: false,
                        imageView: Image(systemName: "sensor.tag.radiowaves.forward.fill")
                            .foregroundColor(Color(red: 46/255, green: 160/255, blue: 67/255))
                            .font(.system(size: 32)),
                        label: NSLocalizedString("DirectConnect", comment: "Title text for button to DirectConnect Settings"),
                        descriptiveText: NSLocalizedString("Dexcom G7 / ONE+ / Stelo without the Dexcom app", comment: "Descriptive text for DirectConnect Settings"))
        }
    }
```

- [ ] **Step 1:** Implement.
- [ ] **Step 2: Commit** — `git commit -m "DirectConnect: settings screens and Loop integration"`

---

### Task 14: Xcode project registration

**Files:**
- Modify: `Loop.xcodeproj/project.pbxproj`
- Create (scratch, not committed): a one-off Python script based on `LoopWorkspace/Scripts/update_pbxproj.py` (`make_uuid` with prefix `FeatureInstaller_`) extended with `.c` (`sourcecode.c.c`) and `.h` (`sourcecode.c.h`) file types.

- [ ] **Step 1:** Add groups `DirectConnect` under `Managers`, `Resources`, `Views`, `LoopTests`; add `Crypto` and `Crypto/micro-ecc` subgroups.
- [ ] **Step 2:** Add every `.swift` under `Loop/` to the Loop target Sources phase; `DirectConnect_ECC.c` to the Loop target Sources phase; `.h` and `micro-ecc/*` as file references only (not compiled; `uECC.c` is `#include`d by `DirectConnect_ECC.c`); test files to the LoopTests Sources phase.
- [ ] **Step 3:** Set `SWIFT_OBJC_BRIDGING_HEADER = "Loop/Managers/DirectConnect/DirectConnect-Bridging.h";` in the Loop target's Debug and Release build configurations.
- [ ] **Step 4:** Verify with `plutil -lint Loop.xcodeproj/project.pbxproj` and a grep that every new file appears exactly once in its build phase.
- [ ] **Step 5: Commit** — `git commit -m "DirectConnect: register files and bridging header in Xcode project"`

**Checkpoint C:** Operator builds the Loop scheme and runs the full LoopTests suite. All must pass. Then device test (spec §1 success criteria 1–6).

---

### Task 15: Documentation and license

**Files:**
- Create: `Loop/Managers/DirectConnect/LICENSE-GPL-3.0.txt` — GPL-3.0 text (copied from xDrip4iOS `LICENSE`) preceded by the list of derived files.
- Create: `Documentation/DirectConnect/DirectConnect_README.md` — user guide per spec §11.
- Create: `Documentation/DirectConnect/DirectConnect_DEVELOPER.md` — developer guide per spec §11.
- Modify: `LoopWorkspace/DIVERGENCE.md` (workspace repo, `feat/AllFeatures`) — add DirectConnect row to the feature table.

- [ ] **Step 1:** Write files.
- [ ] **Step 2: Commit** — Loop repo: `git commit -m "DirectConnect: documentation and GPL notice"`; workspace repo DIVERGENCE.md change is committed with the submodule pointer bump at release time.

---

### Task 16: Option B installer support

**Files (workspace repo, branch `feat/installer`, via temporary worktree):**
- Modify: `Scripts/install_features.sh` — add DirectConnect files to the copy manifest; add `directConnectSettingsRow` to its embedded PowerPack section copy; add the `CGMManager.swift` anchor insert.
- Modify: `Scripts/update_pbxproj.py` — add DirectConnect entries, `.c`/`.h` file types, and the bridging-header build setting.

- [ ] **Step 1:** Implement after Checkpoint C passes on device.
- [ ] **Step 2:** Operator runs an Option B install on a clean LoopWorkspace and builds.
- [ ] **Step 3: Commit** — `git commit -m "Installer: add DirectConnect"`
