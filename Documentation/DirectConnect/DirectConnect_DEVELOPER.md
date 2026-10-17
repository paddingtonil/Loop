# DirectConnect — Developer Guide

Design spec: `DirectConnect_DESIGN.md`. Implementation plan: `DirectConnect_PLAN.md`. Changes after the plan, including device-test follow-ups: `DirectConnect_CHANGELOG.md`.

## Sources

The core of DirectConnect comes from **xDrip4iOS, created by Johan Degraeve** and developed with the
xDrip4iOS contributors. Credit appears in the README, in the DirectConnect settings screen
(Credits), and in `LICENSE-GPL-3.0.txt`.

| Origin | License | Used for |
|---|---|---|
| xDrip4iOS 7.1.1 (`c268542e`), native G7 support added in `ecbb493d` (2026-08-30) | GPL-3.0 | Pairing state machine, J-PAKE math, certificate and proof-of-possession exchange, calibration messages, battery/firmware/extended-version parsers, per-connection command order |
| LoopKit G7SensorKit (`dd91f465`) | MIT | CGMManager structure, persisted state, backfill delivery, Bluetooth central/peripheral managers, status highlights |
| micro-ecc (`541b3a78`) | BSD-2-Clause | P-256 field arithmetic |

There is no compile-time dependency on either project. Every file containing xDrip4iOS-derived code
carries `Portions derived from xDrip4iOS … GPL-3.0` and is listed in
`Loop/Managers/DirectConnect/LICENSE-GPL-3.0.txt`.

## File map

| File | Responsibility |
|---|---|
| `Resources/DirectConnect/DirectConnect_FeatureFlags.swift` | Master flag; "is active CGM" marker |
| `Managers/DirectConnect/DirectConnect_G7CGMManager.swift` | `CGMManager`; turns sensor events into readings, events and alerts |
| `…/DirectConnect_G7State.swift` | Persisted state (`RawRepresentable`) |
| `…/DirectConnect_G7Sensor.swift` | One connection: notify setup, pairing writes, glucose request, one extra command, backfill |
| `…/DirectConnect_BluetoothManager.swift` | `CBCentralManager`, restore ID `com.loopkit.Loop.DirectConnect` |
| `…/DirectConnect_PeripheralManager.swift` | Serialized GATT operations; forwards every unsolicited notification |
| `…/DirectConnect_G7Pairing.swift` | Auth state machine. Bytes in, writes out. No CoreBluetooth |
| `…/DirectConnect_G7Crypto.swift` | AES-ECB, J-PAKE (`DirectConnect_JPAKE`), ZK proofs, proof signature |
| `…/DirectConnect_G7Certificates.swift` | Generated hex constants (do not edit by hand) |
| `…/DirectConnect_KeyStore.swift` | Keychain store for the confirmed 16-byte key |
| `…/DirectConnect_G7Messages.swift` | Opcodes and packet parsers |
| `…/DirectConnect_G7Calibration.swift` | 0x34/0x32 messages and the calibration queue |
| `…/DirectConnect_SensorModel.swift` | G7/ONE+/Stelo identification, lifetimes, connect decision |
| `…/DirectConnect_GlucoseAlarms.swift` | Pure alarm rules → LoopKit `Alert` |
| `…/DirectConnect_AlarmSettings.swift` | Alarm settings model and persistence |
| `…/DirectConnect_Diagnostics.swift` | 3,000-line log kept on disk (`Application Support/DirectConnect/diagnostics.log`) |
| `…/DirectConnect_ConnectionHealth.swift` | 7 days of connection events on disk (`health.json`) and the pure `DirectConnect_HealthSummary` (received/missed wakes, gaps) |
| `…/DirectConnect_KeyStore.swift` (also) | `DirectConnect_LastSensor` / `DirectConnect_LastSensorStore`: the one sensor remembered after Delete CGM (UserDefaults `com.loopkit.Loop.directConnect.lastSensor`); remembering or pairing another sensor erases the older Keychain key |
| `…/DirectConnect_RecoveryPolicy.swift` | Pure timing rules for take-back and the watchdog |
| `Views/DirectConnect/DirectConnect_Tips.swift` | Tip card, numbered steps, all guidance text |
| `Views/DirectConnect/DirectConnect_Branding.swift` | DirectConnect color (Dexcom green) and picker-entry styling |
| `…/DirectConnect_Bytes.swift` | `dc`-prefixed `Data` helpers |
| `…/Crypto/DirectConnect_ECC.c/.h`, `micro-ecc/` | P-256 point add/subtract/multiply (CryptoKit lacks these) |
| `…/DirectConnect-Bridging.h` | Loop target bridging header (C → Swift) |
| `Views/DirectConnect/*` | CGMManagerUI conformance, coordinator, setup, status, calibration, diagnostics, settings, alarms |

## Delete CGM and reconnect

`delete()` remembers the current sensor (`DirectConnect_LastSensorStore.remember`), keeps its key,
and calls `sensor.shutDown()` → `BluetoothManager.shutDown()`: no scan, discovery or reconnect
afterwards (a plain disconnect rescans 2 s later). Setup shows "Reconnect to <name>";
`DirectConnect_UICoordinator.completeReconnect(to:)` builds the manager from
`DirectConnect_LastSensor.reconnectState` (short authentication; full pairing with the stored code
if the key is refused). `didPairWith` calls `forget(unless:)` and erases the previous sensor's key.
Untested on a device: the deleted and new managers briefly hold CBCentralManagers with the same
restore identifier.

The Add CGM list shows `pickerTitle` (no bolt: with the private purple title color the sheet drew
the emoji as a missing-glyph box), centered with the private `titleTextAlignment` key.
`DirectConnect_PickerStyleTests` fails if iOS drops `_titleTextColor` or `_titleTextAlignment`.

## Changes to existing Loop files

| File | Change |
|---|---|
| `Loop/Managers/CGMManager.swift` | Registers `DirectConnect_G7CGMManager` in `staticCGMManagersByIdentifier` (always) and lists it in `availableStaticCGMManagers` (flag on) |
| `Loop/Views/SettingsView.swift` | `directConnectSettingsRow` in the PowerPack section; purple Add CGM entry in the plugin picker |
| `Loop/Extensions/UIAlertController.swift` | Purple Add CGM entry (`DirectConnect_Branding.style`) |
| `Loop/Info.plist` | `dexcomg7` in `LSApplicationQueriesSchemes` (detects an installed Dexcom app) |
| `Loop.xcodeproj/project.pbxproj` | Files, groups, `SWIFT_OBJC_BRIDGING_HEADER` on the Loop target (Debug, Release) |

`uECC.c` is `#include`d by `DirectConnect_ECC.c` with curve flags and must never be added to
Compile Sources.

## Connection sequence

1. Bluetooth manager connects the followed sensor (`makeActive`) or, when scanning, any sensor of
   the chosen type that is not the previous one or a rejected candidate (`connect`). No unknown
   sensor is connected until a pairing code exists.
2. Enable notify on `Auth_Stream` (F8083538), then `Receive_Authentication` (F8083535). Order
   matters: the sensor can stream a J-PAKE payload immediately after a phase announcement.
3. `DirectConnect_G7Pairing.start()`:
   - saved key → `02 <8-byte token> 02` (short auth)
   - no key → `0A 00` (J-PAKE phase 0)
4. Short auth: `03 hash challenge` → `04 AES(challenge‖challenge)[0..<8]` → `05 auth paired`.
5. Full ownership: J-PAKE phases 0–2 (160-byte payloads on the stream; replies as 20-byte
   fragments spaced 40 ms, then the control packet) → short auth with the derived key →
   certificates phase 0 (send part A), 1 (send part B), 2 → `0C <16-byte challenge>` → sign
   SHA-256(challenge) with the fixed key, send 64-byte r‖s + `0D 00 02` → `0D` → `06 19` →
   `06 01` (confirm and save key) or `06 00` → `07` → `07 00` → `08 01` (confirm and save key).
6. Enable notify on `Write_Control` (F8083534); write `4E` once.
7. On a status-0 glucose: set the calibration clock reference, enable `Backfill` notify, send at
   most one extra command: calibration (0x34 or 0x32) → extended version (0x52) → firmware
   (0x4A + CRC) → battery (0x22 + CRC, every 2 h).
8. `59` or disconnect flushes backfill. Disconnect requeues an unacknowledged calibration.

| Pairing event | Action |
|---|---|
| `rejectedSavedKey` | Stop reconnecting to this sensor (`authenticationBlocked`), show "Pairing lost" |
| `needsCleanReconnect` | Key already deleted by the pairing machine; disconnect; next wake pairs fully |
| `codeRejected` | While scanning, skip that sensor; show the wrong-code message |
| `failed` | Log and disconnect |

## Readings

- Reading time = activation + `glucoseTimestamp`, where activation = receive time − `messageTimestamp`
  (G7SensorKit's interpretation).
- Calibration clock = (`messageTimestamp`, receive time − `age`) (xDrip4iOS's interpretation, which
  matches the calibration-bounds captures in the tests).
- Dropped: non-zero response status, sensor failed or session ended, after `sensorEndsAt`,
  unreliable algorithm state, six identical values in a row.
- A new session (activation moved by more than 1 h) emits a `sensorStart` `PersistedCgmEvent` and
  resets alarm state.

## Tests

`LoopTests/DirectConnect/` — run in Xcode (Loop scheme, LoopTests).

| Test file | Covers |
|---|---|
| `DirectConnect_AlarmSettingsTests` | Defaults, ranges, ordering, persistence |
| `DirectConnect_G7MessagesTests` | Parsers, captured xDrip4iOS frames, CRC check value |
| `DirectConnect_SensorModelTests` | Type detection, lifetimes, connect decisions |
| `DirectConnect_G7CryptoTests` | FIPS-197 AES vector, CryptoKit cross-check of point math, ZK proofs, full two-sided J-PAKE with a reference sensor, proof signature |
| `DirectConnect_G7PairingTests` | Every auth branch, key saved only on ownership confirmation |
| `DirectConnect_G7CalibrationTests` | xDrip4iOS calibration vectors and queue behavior |
| `DirectConnect_GlucoseAlarmsTests` | Issue, repeat, retract rules for each alarm |
| `DirectConnect_StateTests` | Raw-state round trip, stuck-sensor rule |
| `DirectConnect_RecoveryPolicyTests` | Take-back spacing, repeated-takeover window, watchdog |
| `DirectConnect_ConnectionHealthTests` | Coverage, missed wakes, gaps, withheld readings, on-disk log |

Calibration queue rules added after device testing (see `DirectConnect_CHANGELOG.md`): a new value
replaces one still processing; processing ends after 6 bounds requests or 30 minutes
(`expireIfOverdue`, called each minute); `lastCompleted` records the last confirmed value.

Not unit-tested (needs a sensor): the Bluetooth managers, `DirectConnect_G7Sensor`, the CGM manager
wiring, and the screens.

## Porting future xDrip4iOS fixes

Watch these xDrip4iOS files: `DexcomG7AuthSession.swift`, `DexcomG7AuthBridge.m`,
`DexcomG7ECC.c`, `CGMG7Transmitter.swift`, `DexcomG7CalibrationMessages.swift`,
`DexcomG7DiagnosticMessages.swift`. Map each change to the matching DirectConnect file in the
table above, add a test with any new packet capture, and keep the credit line.
