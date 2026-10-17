# DirectConnect — Design Spec

*Loop (AID) PowerPack. Status: approved design, 2026-10-09. Branch: `feat/DirectConnect` (Loop repo).*

## 1. Goal

Let a person with a Dexcom G7, Dexcom ONE+, or Dexcom Stelo sensor use **Loop as the only app**.
Loop pairs with the sensor, receives glucose, calibrates, and raises glucose alarms. The Dexcom app
is not installed or not running.

DirectConnect is a **PowerPack Exclusive** feature: it exists only in PowerPack builds, and the UI
labels it that way.

### Success criteria

1. With the Dexcom app deleted, a new G7, ONE+, or Stelo sensor pairs in Loop using the 4-digit
   applicator code and delivers a reading every 5 minutes.
2. After a Bluetooth gap, missed readings are filled from the sensor's history.
3. Loop runs its loop on each sensor reading (the sensor connection keeps Loop awake in the
   background).
4. Urgent Low, Low, High, Rising Fast, and Falling Fast alarms fire from Loop.
5. Calibration, the 15-day option, and the diagnostics screen work.
6. With the feature flag OFF, nothing about Loop's behavior or CGM list changes.

### Non-goals

- Coexistence with the Dexcom app (Loop already has that through G7SensorKit).
- Dexcom Clarity or Dexcom Share upload. (Loop's existing Nightscout upload still works.)
- Dexcom G6, Libre, Eversense, or any non-G7-family sensor.
- Any change to the dosing algorithm.

## 2. Decisions already made

| Decision | Choice |
|---|---|
| Where the code lives | Inside the Loop app target, as a built-in CGM option |
| Source of code | Taken from xDrip4iOS 7.1.1 (commit `c268542e`, native G7 support added in `ecbb493d`) and LoopKit G7SensorKit; rewritten into self-contained `DirectConnect_` files with no dependency on either project |
| Scope of version 1 | Core + calibration + 15-day switch + Stelo/ONE+ + diagnostics screen |
| Alarms | Urgent Low (fixed 55 mg/dL, always on), Low, High, Rising Fast, Falling Fast |
| Feature flag | `DirectConnect_FeatureFlags.isEnabled`, default OFF |

## 3. Licensing and attribution (required, not optional)

- xDrip4iOS is **GPL-3.0**. Every file that contains code derived from xDrip4iOS keeps a header
  line: `Portions derived from xDrip4iOS (https://github.com/JohanDegraeve/xdripswift), GPL-3.0.`
- `Loop/Managers/DirectConnect/LICENSE-GPL-3.0.txt` holds the GPL text and a list of the derived files.
- micro-ecc (BSD-2-Clause) keeps its own `LICENSE.txt`.
- Code derived from G7SensorKit (MIT) keeps the LoopKit copyright line.
- `DIVERGENCE.md` and `DirectConnect_README.md` state the GPL status.
- The pairing protocol embeds a fixed client certificate and signing key used by the G7 ownership
  exchange. The operator chose to proceed after being told of the legal risk of shipping this
  material (2026-10-09).

## 4. Architecture

```
Loop app target
├── Loop/Managers/CGMManager.swift            (anchor insert: register DirectConnect when flag ON)
├── Loop/Views/SettingsView.swift             (anchor insert: DirectConnect row in PowerPack section)
│
├── Loop/Resources/DirectConnect/
│   └── DirectConnect_FeatureFlags.swift      master flag + per-user settings keys
│
├── Loop/Managers/DirectConnect/
│   ├── DirectConnect_G7CGMManager.swift      CGMManager + CGMManagerUI conformance; the only type Loop sees
│   ├── DirectConnect_G7State.swift           RawRepresentable persisted state
│   ├── DirectConnect_G7Sensor.swift          per-connection lifecycle: connect → auth → glucose → extras → disconnect
│   ├── DirectConnect_BluetoothManager.swift  CBCentralManager, scan/reconnect by sensor name
│   ├── DirectConnect_PeripheralManager.swift characteristic discovery, ordered writes, notify setup
│   ├── DirectConnect_G7Pairing.swift         auth state machine (J-PAKE, certificates, proof of possession, short auth)
│   ├── DirectConnect_G7Crypto.swift          Swift port of xDrip's Objective-C auth bridge (AES, SHA-256, J-PAKE math via C)
│   ├── DirectConnect_KeyStore.swift          Keychain storage of the confirmed shared key, per sensor + slot
│   ├── DirectConnect_G7Messages.swift        opcodes; glucose (0x4E), backfill, extended version (0x52), battery, firmware
│   ├── DirectConnect_G7Calibration.swift     0x34 command, 0x32 bounds record, queued retry
│   ├── DirectConnect_SensorModel.swift       G7 / ONE+ / Stelo detection, warmup, lifetime (10.5 d / 15.5 d)
│   ├── DirectConnect_GlucoseAlarms.swift     threshold + rate evaluation → LoopKit Alert
│   ├── DirectConnect_Diagnostics.swift       firmware, RSSI, auth state, rolling log for export
│   ├── DirectConnect-Bridging.h              exposes the C ECC API to Swift
│   ├── LICENSE-GPL-3.0.txt
│   └── Crypto/
│       ├── DirectConnect_ECC.h / .c          P-256 point add/subtract/scalar ops (from xDrip's DexcomG7ECC.c)
│       └── micro-ecc/                        vendored, pinned revision 541b3a78, LICENSE.txt
│
├── Loop/Views/DirectConnect/
│   ├── DirectConnect_SettingsView.swift      master toggle ("PowerPack Exclusive"), link to alarms
│   ├── DirectConnect_AlarmSettingsView.swift per-alarm on/off, threshold, repeat interval
│   ├── DirectConnect_SetupView.swift         sensor type → 4-digit code → pairing progress
│   ├── DirectConnect_SensorStatusView.swift  reading, trend, warmup, age, expiry, battery
│   ├── DirectConnect_CalibrationView.swift
│   └── DirectConnect_DiagnosticsView.swift
│
├── LoopTests/DirectConnect/                  unit tests (see §9)
└── Documentation/DirectConnect/              README, DEVELOPER, this DESIGN
```

### Unit boundaries

| Unit | Does | Depends on |
|---|---|---|
| `G7CGMManager` | Translates sensor events into Loop's `CGMManagerDelegate` calls; owns state and alarms | Sensor, State, Alarms |
| `G7Sensor` | Runs one connection's ordered steps | Bluetooth/Peripheral managers, Pairing, Messages, Calibration |
| `G7Pairing` | Decides the next auth packet from the last received packet | Crypto, KeyStore — no CoreBluetooth types (bytes in, bytes out) so it is unit-testable |
| `G7Crypto` | Pure functions over bytes | CommonCrypto, C ECC |
| `G7Messages` | Parse/build packets | Foundation only |
| `GlucoseAlarms` | Pure evaluation: (readings, settings, active alarms) → alerts to issue/retract | LoopKit `Alert` types only |

`G7Pairing` differs from xDrip's `DexcomG7AuthSession`: xDrip passes `CBCharacteristic` objects into
the session. DirectConnect's version takes and returns `Data` plus a target characteristic enum, so
tests can feed recorded packets without Bluetooth.

## 5. Feature flag and integration with Loop

### Flag

`DirectConnect_FeatureFlags.isEnabled` — UserDefaults key `com.loopkit.Loop.directConnectFeatureEnabled`,
default `false`. Same pattern as `AutoPresets_FeatureFlags`.

### Registration (anchor insert in `Loop/Managers/CGMManager.swift`)

`staticCGMManagersByIdentifier` gains `DirectConnect_G7CGMManager.pluginIdentifier` →
`DirectConnect_G7CGMManager.self`. `availableStaticCGMManagers` filters it out when the flag is OFF.
Restoring an already-configured DirectConnect CGM from saved state works regardless of the flag, so
a flag flip can never orphan the active CGM.

Identifier: `PowerPackDirectConnectG7`. Display title: `Dexcom G7/ONE+ using DirectConnect ⚡️`.

### Turning the flag off

The toggle is disabled while DirectConnect is the active CGM, with the text
"Remove the DirectConnect CGM in Settings → CGM before turning this off."

### Settings (anchor insert in `Loop/Views/SettingsView.swift`)

One `NavigationLink` row inside the existing purple PowerPack section, matching the other features.
Because `install_features.sh` embeds its own copy of the PowerPack section code, the same row is
added there.

## 6. Sensor connection flow

1. **Setup.** User picks sensor type (G7 / ONE+ / Stelo), enters the 4-digit applicator code.
   For G7, the user also sets "15-day sensor" if applicable (default off; the sensor's own 0x52
   response overrides it once received).
2. **Scan.** Scan for the Dexcom advertisement service; accept the first `DX..` name that is not a
   previously used sensor. Save the name as the sensor ID.
3. **First connection — full ownership.** J-PAKE in three phases using the code as the password →
   certificate exchange (phases 0, 1, 2) → proof of possession → keep-alive → bond request → pair
   confirmation. The derived 16-byte key is saved to the Keychain **only after** the sensor confirms
   ownership.
4. **Later connections — short auth.** Auth request with saved key → AES challenge response →
   authenticated.
5. **Data.** Request glucose (0x4E). On a valid reading: send it to Loop, then send at most one
   extra request per wake in this order: pending calibration → lifetime (0x52) if unknown →
   firmware if unknown → battery if older than 2 hours.
6. **Backfill.** After a gap, request backfill; hold packets until a valid reading fixes the
   sensor clock reference, then date and deliver them.
7. **Disconnect.** Sensor disconnects itself; reconnect is left pending so iOS wakes Loop at the
   next sensor advertisement (about every 5 minutes).

Bluetooth slot: `mobileApp` (0x2), the default xDrip uses. This is the slot the Dexcom app would use,
which is fine because the Dexcom app is not in use.

### Readings passed to Loop

Each `NewGlucoseSample` uses `device` info with the sensor ID and firmware, `isDisplayOnly: false`,
`wasUserEntered: false`, and the trend from the sensor. Readings are rejected (not sent) when:
the sensor is in warmup, past its lifetime, reports an algorithm error state, the value is outside
40–400 mg/dL, or the value has been identical for 30 minutes (xDrip's faulty-sensor rule).

## 7. Glucose alarms

Evaluated on every new reading in `DirectConnect_GlucoseAlarms` and issued through the
`CGMManagerDelegate` alert path (`issueAlert` / `retractAlert`).

Every alarm is configured by the user in `DirectConnect_AlarmSettingsView` (Settings → PowerPack →
DirectConnect → Alarms). Each alarm has an on/off switch, a threshold (where one applies), and a
repeat interval. The values below are defaults and allowed ranges.

| Alarm | Default threshold (range) | Default repeat (range) | Default on | Interruption level |
|---|---|---|---|---|
| Urgent Low | 55 mg/dL (40–70) | 5 min (5–30) | Yes | `.critical` |
| Low | 70 mg/dL (55–100) | 15 min (5–60) | Yes | `.timeSensitive` |
| High | 250 mg/dL (120–400) | 60 min (15–240) | Yes | `.timeSensitive` |
| Rising Fast | 3 mg/dL/min (2–5) | once per episode | No | `.active` |
| Falling Fast | 3 mg/dL/min (2–5) | once per episode | Yes | `.timeSensitive` |
| Signal Loss | 20 min without a reading (10–60) | once per gap | Yes | `.timeSensitive` |
| Sensor Expiring | 24 h and 2 h before end | once each | Yes | `.active` |
| Sensor Failed / Ended | sensor reports failure or end | once | Yes | `.timeSensitive` |

Turning Urgent Low off requires a confirmation dialog stating that Loop will not warn about urgent
lows. The Urgent Low threshold must stay below the Low threshold, and Low below High; the settings
view enforces this.

An alarm is retracted when glucose returns past its threshold. Thresholds are stored in mg/dL and
shown in the user's display unit. Settings are stored in UserDefaults under
`com.loopkit.Loop.directConnect.alarm.*` keys, read by `DirectConnect_GlucoseAlarms` on each
evaluation so changes apply at the next reading.

**Known limit:** Loop does not have Apple's Critical Alerts entitlement. `.critical` alerts follow
Loop's existing alert behavior (Loop plays its own alert sound when its audio session allows it).
Whether Urgent Low is heard with the phone on silent must be verified on a device and documented in
the README.

## 8. Error handling

| Condition | Behavior |
|---|---|
| Wrong applicator code | J-PAKE validation fails → setup shows "Code not accepted. Check the 4 digits on the applicator." No key saved. |
| Saved key rejected by sensor | Stop reconnecting; sensor status shows "Pairing lost — re-enter code"; Signal Loss alarm applies |
| Incomplete ownership after disconnect | Clean reconnect and restart full ownership (xDrip's `authSessionRequiresCleanReconnect`) |
| Sensor taken over by another app | Same as key rejected |
| Calibration rejected (0x32 reason) | Show the reason text from the bounds record; calibration not retried |
| Calibration interrupted | Kept queued; sent on next connection |
| Bluetooth off / unauthorized | `cgmManagerStatus` reports it; status view shows it |
| Sensor expired | Readings stop; Sensor Ended alert; status view offers "Add new sensor" |

All failures are written to the diagnostics log.

## 9. Testing

Test-first for every pure unit. Tests live in `LoopTests/DirectConnect/` and are named
`DirectConnect_<Unit>Tests.swift`.

| Test file | Covers | Test data source |
|---|---|---|
| `DirectConnect_G7MessagesTests` | glucose, backfill, extended version (10 d / 15 d), battery, firmware parsing | packet bytes from xDrip's code comments and tests |
| `DirectConnect_G7CryptoTests` | AES challenge response, SHA-256 hashing, ECC point ops, J-PAKE zero-knowledge proof check | fixed vectors computed from xDrip's implementation |
| `DirectConnect_G7PairingTests` | auth state transitions, key saved only after confirmation, rejected-key path | scripted packet sequences |
| `DirectConnect_G7CalibrationTests` | 0x34 build, 0x32 match/reject reasons | ported from xDrip `DexcomG7CalibrationTests.swift` |
| `DirectConnect_SensorModelTests` | G7 / ONE+ / Stelo lifetime and warmup, 15-day override | — |
| `DirectConnect_GlucoseAlarmsTests` | each alarm's issue, repeat, retract rules | synthetic reading sequences |
| `DirectConnect_StateTests` | raw state round trip | — |

The operator builds and runs tests in Xcode (no builds by the agent). Device testing on real
G7/ONE+/Stelo sensors is done by the operator.

## 10. Build and install configuration

- **Xcode project:** add all files to the Loop target; add the test files to LoopTests; set
  `SWIFT_OBJC_BRIDGING_HEADER = Loop/Managers/DirectConnect/DirectConnect-Bridging.h` on the Loop
  target (Debug and Release). The `.c` files compile in the Loop target; micro-ecc's `uECC.c` is
  included from `DirectConnect_ECC.c` only (not added to Compile Sources), as xDrip does.
- **Info.plist:** no change; `bluetooth-central` background mode and Bluetooth usage text already exist.
- **Option B installer (`Scripts/install_features.sh` on `feat/installer`):** add the new files to
  the manifest; add the bridging header build setting through `update_pbxproj.py`; add the Settings
  row to its embedded PowerPack section copy.
- **Version:** ships in the next PowerPack release after device testing.

## 11. Documentation

- `DirectConnect_README.md` — user guide: what it does, PowerPack Exclusive, setup, alarms,
  silent-switch behavior, calibration, 15-day option, what is lost without the Dexcom app
  (Clarity, Share), GPL notice.
- `DirectConnect_DEVELOPER.md` — file map, connection sequence, auth protocol notes, test plan,
  how to port future xDrip4iOS fixes.
- `DIVERGENCE.md` — new row in the feature table.

## 12. Risks

| Risk | Mitigation |
|---|---|
| xDrip's native G7 code is 6 weeks old and had 3 fixes since | Port the latest version (includes the Sep 3, 5, 20 fixes); device testing before release |
| Dexcom firmware change breaks pairing | Diagnostics log; feature stays opt-in; Loop's G7SensorKit coexistence option remains available |
| Legal claim over the embedded certificate | Accepted by operator; feature isolated so it can be removed by deleting the DirectConnect folders and two anchor inserts |
| Urgent Low silent on mute | Verified on device; documented |
