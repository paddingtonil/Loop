# DirectConnect — Change Log

Branch `feat/DirectConnect` (Loop repo). Not yet committed or released.

## 2026-10-18 — Urgent Low alarm was not heard overnight

### Finding (from the diagnostics log)
Glucose stayed under 50 mg/dL from about 12:00 to 2:30 AM Pacific. `Alarm: urgentLow` was logged
six times (12:01, 12:26, 1:41, 1:56, 2:11, 2:21 AM), so the alarm rules fired correctly. None was
heard. Loop is built without Apple's critical-alert permission (`CRITICAL_ALERTS_ENABLED` off, no
entitlement), so the Urgent Low notification was delivered as an ordinary notification, which only
vibrates on silent.

### Changes
| Change | Files |
|---|---|
| Loop plays each alarm's sound with its own audio player | `DirectConnect_GlucoseAlarms.swift` (new `DirectConnect_AlarmPlayer`), `DirectConnect_G7CGMManager.swift` |
| Per-alarm Play Through Silent switch. On: `.playback` audio category (not muted by the silent switch or a Focus), system volume raised to full and restored afterwards, Loop's Mute Alerts ignored. Off: `.ambient` category (muted by the silent switch), Mute Alerts applies. Default on for Urgent Low and Falling Fast (turning it off asks for confirmation), off for the others | same, `DirectConnect_AlarmSettingsView.swift` |
| Urgent Low and Falling Fast repeat until acknowledged, until Loop is opened, or until the alarm clears, and cannot be set to no sound. Other alarms play the sound three times | same |
| Sound choices Siren, Alarm Clock, Pulse, Chime, None; generated in code as WAV data, no audio files added | `DirectConnect_AlarmSettings.swift` (`DirectConnect_AlarmSound`, `DirectConnect_AlarmPlayback`) |
| Per-alarm Sound picker and Test Sound button (6 seconds, same rules as a real alarm) | `DirectConnect_AlarmSettingsView.swift` |
| Every play, skip and failure is written to the diagnostics log with the volume | `DirectConnect_G7CGMManager.swift` |
| Tests: play-through on and off, defaults, urgent alarms cannot be silent, sound settings round trip, every sound renders audible WAV data | `DirectConnect_AlarmSettingsTests.swift` |

### Old alarm shown again at launch
After installing the build, Loop showed "Urgent Low Glucose — Glucose is 45 mg/dL" with glucose at
105. That was the 2:11 AM alert. Urgent Low repeated at 2:11 and 2:21 AM under the same alert
identifier; when the low ended, Loop's `AlertStore.recordRetraction` marked only the latest alert
(2:21) retracted, and Loop re-shows unretracted, unacknowledged alerts at every launch. Change:
DirectConnect retracts an alarm's earlier alert before issuing it again
(`DirectConnect_GlucoseAlarms.steps(for:)`, used by `DirectConnect_G7CGMManager.apply`), with a
test in `DirectConnect_GlucoseAlarmsTests.swift`. LoopKit's `AlertStore.swift` is unchanged.
The alert already left open on the phone stays until OK is pressed once.

### xDrip4iOS sound library
The 117 sounds xDrip4iOS offers (its `ConstantsSounds.swift`, commit c268542) were added as data
sets in `Loop/DefaultAssets.xcassets/DirectConnectSounds/`, converted from 94 MB of PCM to 13 MB of
AAC with `afconvert -d aac -b 96000`. An asset catalog already in the Loop target holds them, so the
Xcode project file is unchanged. `DirectConnect_AlarmSound` became a struct covering the 4 generated
tones and the xDrip4iOS sounds. The Sound row opens a list screen with both groups; tapping a sound
selects it and plays it for 6 seconds with that alarm's play-through rules, and the list stays open
(as in iOS Settings → Sounds). Tests check
every xDrip4iOS sound loads from the app. The Option B installer must copy the
`DirectConnectSounds` folder (not yet changed).

### Per-alarm volume
Each alarm has a Volume setting (10–100%, default 40%) on its Sound list screen; the slider replays
the selected sound at the new level. While any alarm sounds, Loop sets the phone's media volume to
that level and restores it afterwards. This replaces the full-volume rule for play-through alarms,
so Urgent Low and Falling Fast also start at 40%. Tests: default 40%, round trip, 10% minimum,
playback uses the alarm's own level.

### Not yet checked on a device
- That the sound starts during a background sensor wake with the phone locked.
- That setting the volume with `MPVolumeView` works in the background. iOS has no public call for
  this; if it does not work, the alarm plays at the phone's current media volume.

## 2026-10-09 — First build and device test

### Built
- Complete feature per `DirectConnect_DESIGN.md` and `DirectConnect_PLAN.md` Tasks 1–15
  (Task 16, Option B installer support, waits for device testing).
- 104 unit tests in `LoopTests/DirectConnect/` (not yet run in Xcode).

### Build errors found by the first Xcode builds, and what was changed
| Error | Change |
|---|---|
| `ShareLink` is iOS 16 only; the Loop target compiles for iOS 15.1 | Share Diagnostics button shown only on iOS 16+ (`#available`); Copy Diagnostics always shown |
| `DirectConnect_G7CGMManager` defined `localizedTitle` as both a static and an instance member | Static renamed `displayTitle`; instance `localizedTitle` returns it |
| micro-ecc C code failed Loop's warnings-as-errors settings | `DirectConnect_ECC.c` disables warnings for that file only with a `#pragma clang diagnostic` push/pop; project settings unchanged |
| `DirectConnect_SetupView` arguments passed out of declared order | Argument order corrected in `DirectConnect_SensorStatusView` |

### Device test result
A G7 15-day sensor already in session (DXCMcl) paired with no Dexcom app, delivered glucose,
and reported its 15.5-day session length within about 2 minutes of pairing.

### Changes requested after the device test
| Request | What changed | Files |
|---|---|---|
| Trend row looked like a tap target | Trend shows words, arrow and rate, e.g. "Flat → (+0.1 mg/dL/min)" | `DirectConnect_SensorStatusViewModel.swift` |
| Make sensor replacement obvious | New "What to do now" tip card that changes with sensor state (searching, warmup, < 24 h left, grace period, ended, failed); "How to change your sensor" 6-step guide that opens automatically in grace period / ended / failed; "Before you pair" checklists on first pairing and on Pair New Sensor; expiring and ended alarms name the Pair New Sensor path | new `DirectConnect_Tips.swift`; `DirectConnect_SensorStatusView.swift`, `DirectConnect_SetupView.swift`, `DirectConnect_GlucoseAlarms.swift`, `DirectConnect_README.md` |
| Header should name the feature | Sensor screen header reads "<sensor type> DirectConnect", e.g. "Dexcom G7 DirectConnect" | `DirectConnect_SensorStatusView.swift` |
| 10-day vs 15-day should not need user input | "15-day sensor" switch removed. Session length and warmup come from the sensor's own report after pairing. Before a G7 reports, length shows "Detecting…" and no expiration dates are shown; Stelo (15-day only) and ONE+ (10-day only) are known from type. Session-end checks use only a reported length, so a guess can never end a session early. Instructions no longer mention 10-day or 15-day | `DirectConnect_SensorModel.swift`, `DirectConnect_G7State.swift`, `DirectConnect_G7CGMManager.swift`, `DirectConnect_SetupView.swift`, `DirectConnect_SensorStatusView(Model).swift`, `DirectConnect_UICoordinator.swift`, `DirectConnect_Tips.swift`, tests |
| Distinct color in the CGM pickers | DirectConnect entry colored in the home-screen "Add CGM" list and Settings → CGM picker (private `UIAlertAction.titleTextColor`, set only after confirming it exists) | new `DirectConnect_Branding.swift`; `Loop/Extensions/UIAlertController.swift`, `Loop/Views/SettingsView.swift` |
| Use Dexcom green, not purple | Single DirectConnect color = Dexcom green, Pantone 369 C, #64A70B (not verified against Dexcom's brand guide). "PowerPack Exclusive" badge stays PowerPack purple | `DirectConnect_Branding.swift` and its users |
| Feature switch could not be turned off | Confirmed intended: locked while DirectConnect is the active CGM. Kept as is | none |

### Readings stopped at 7:50 PM while the Dexcom app still read the sensor
Evidence (diagnostics, 8:15 PM): connect → authenticated in 7 s; glucose frame
`4e00fb710c009f0a0001ec058e0019f7ffff02` = status 0, reading age 1,516 s (25 min, from 7:50:39 PM),
algorithm state 25. The sensor was handing DirectConnect a cached reading, not live data.
Likely cause (not proven): the Dexcom app, still installed with this sensor, reconnects in the
background and re-paired into the same phone-app slot (0x02) after DirectConnect did. DirectConnect
then showed "Sensor failed" from the cached frame's state.

Changes:
- A reading 10 minutes or older is no longer stored or delivered. The sensor screen shows: the sensor
  is sending only an old reading from <time>; another app (usually the Dexcom app, even unopened)
  has likely paired after Loop; delete the Dexcom app or remove the sensor from it, then Re-enter
  Pairing Code; if no other app uses the sensor, it may have failed. The next live reading clears it.
- Non-zero-status glucose frames are logged only, no longer stored as the latest reading (their stale
  algorithm state could show a working sensor as failed).
- Diagnostics log is kept on disk (`Application Support/DirectConnect/diagnostics.log`, last 3,000
  lines), so it survives restarts and rebuilds.
Files: `DirectConnect_G7CGMManager.swift`, `DirectConnect_Diagnostics.swift`, `DirectConnect_DiagnosticsView.swift`.

Not yet decided: pairing in the smartwatch slot (0x03) so DirectConnect and the Dexcom app do not
replace each other. Supported by xDrip4iOS; not confirmed on a device to deliver live data.

### DirectConnect takes over the sensor and keeps it (connection hardening)
Requirement: selecting DirectConnect overrides any Dexcom connection; no external app needed.
- Automatic take-back: a refused saved key, or 2 cached (stale) readings in a row, makes Loop re-pair
  with the stored applicator code at the next sensor wake (at most once per 5 minutes). Repeated
  take-backs (2 in 6 hours) show a warning to delete the Dexcom app.
- Dexcom G7 app detection (`dexcomg7` added to `Loop/Info.plist` LSApplicationQueriesSchemes):
  setup and sensor screens show "Delete the Dexcom app" when it is installed.
- The sensor's CoreBluetooth identifier is saved; at launch Loop queues a connection to that exact
  sensor (no scan), and connects to it even if iOS has not cached its name.
- Bluetooth steps: 5-second timeouts (was 2) and one retry for notification setup and control
  writes; a failed control setup ends the connection cleanly so the next wake starts fresh.
- Removed a blocking queue hop that could stall the Bluetooth queue up to the command timeout.
- Watchdog: 11 minutes without a connection restarts the pending connection (once per 10 min).
Files: new `DirectConnect_RecoveryPolicy.swift` (+ tests); `DirectConnect_G7CGMManager.swift`,
`DirectConnect_G7Sensor.swift`, `DirectConnect_BluetoothManager.swift`,
`DirectConnect_PeripheralManager.swift`, `DirectConnect_G7State.swift`, `DirectConnect_Tips.swift`,
`DirectConnect_SetupView.swift`, `DirectConnect_SensorStatusView.swift`, `Loop/Info.plist`.

### Device log 8:45–8:51 PM (Dexcom app deleted, iPhone restarted)
- Pair New Sensor could not re-pair the same sensor (it skipped the previous sensor by name). Now
  the name skip is removed and a search always does full pairing with the entered code.
- 8:45 PM: iOS reported one connection twice; pairing restarted mid-exchange and the sensor refused
  the certificate step. Now a duplicate report on an active connection is ignored, and a candidate
  that is already connecting is not connected again (`DirectConnect_G7Sensor.swift`,
  `DirectConnect_BluetoothManager.swift`).
- 8:51 PM: full ownership succeeded, but the sensor again returned reading 2719 from 7:50 PM
  (56 min old, state 25). With no other app present, the sensor itself stopped producing glucose.
  Recommended: replace the sensor; test DirectConnect end to end on the new one.

### New sensor DXCMSq overnight, 9:13 PM–6:02 AM
- Bluetooth: connected at all ~105 five-minute wakes in a row, with no missed sequence numbers.
- From about 2:57 AM the sensor mostly sent state 18 (temporary sensor issue) at 20–30 mg/dL. Loop
  does not save those values, so the graph showed gaps. Loop showed that state as "Sensor is
  warming up"; it now says "Temporary sensor issue…" (`DirectConnect_G7Messages.swift`).
- Calibration stuck on "Processing": the 185 mg/dL calibration was accepted, but the sensor
  never sent a final result that matched it. The calibration queue then:
  - refused every new calibration;
  - sent a bounds request (0x32) at every wake, which used the only extra-command slot, so
    battery and session-length reads stopped.
  Now (`DirectConnect_G7Calibration.swift`):
  - a new calibration replaces one that is still processing;
  - bounds requests stop after 6 wakes, with status "Sent. The sensor did not report whether it
    used the value.";
  - the calibration screen gives a separate message for out of range and for waiting to send
    (`DirectConnect_CalibrationView.swift`);
  - calibration commands and responses are written to the diagnostics log
    (`DirectConnect_G7Sensor.swift`).
  Tests are in `DirectConnect_G7CalibrationTests.swift`.

### Add CGM list entry
- Title is now "Dexcom G7 / ONE+ / Stelo — PowerPack DirectConnect ⚡" (was "… (DirectConnect)"),
  so it is not mistaken for Loop's own "Dexcom G7" entry, which needs the Dexcom app.
- Entry text is PowerPack purple, lighter in dark mode (`DirectConnect_Branding.pickerUIColor`).
- The stored CGM uses the plugin identifier, not the title, so an already-paired sensor is unaffected.

### Connection Health
- New `DirectConnect_ConnectionHealth.swift`: keeps 7 days of connection events on disk
  (`Application Support/DirectConnect/health.json`): new readings (usable or withheld by the
  sensor), old cached readings, take-backs, pairing failures.
- Diagnostics screen shows, for the last 24 hours and 7 days: wakes received of expected, missed
  wakes, number of gaps, longest gap. Copy Diagnostics includes the same numbers. Clear Logs
  also clears these counts.
- Tests: `DirectConnect_ConnectionHealthTests.swift`.

### Calibration "Processing" that never ends
- Processing now also ends 30 minutes after the sensor accepted the value, checked once a minute,
  even when the sensor is not waking. Before, it ended only after 6 sensor wakes.
- The Calibrate screen now updates when the status changes without a command being sent
  (dropped as stale, or gave up). Before, it kept the old status until the connection ended.
- A sensor answer that does not match the calibration is now logged as ignored.
- Status saved as Processing by an older build with nothing awaited is changed to unconfirmed.

### App launch: connect before Bluetooth is ready
- Console at launch showed "API MISUSE: <CBCentralManager> can only accept this command while in
  the powered on state" right after "Restoring peripheral". iOS hands back the sensor before
  Bluetooth reports powered on, and DirectConnect called connect at once. iOS ignored the call.
  The powered-on callback then connected normally, so no reading was lost.
- `DirectConnect_BluetoothManager.swift` now connects only when Bluetooth is powered on.

### Color
- DirectConnect green is now #74A52E, the In Range green used by LoopInsights Time in Range
  (`clarityGreen`), replacing the unverified #64A70B.

### Add CGM list entry, shorter
- Title is now "Dexcom G7/ONE+ using DirectConnect ⚡️" so it fits on one line in the Add CGM sheet
  (the long title was shrunk to a small font). Stelo still works; only the list title omits it.
- The bolt carries the emoji variation selector (U+FE0F): the sheet drew the bare U+26A1 as a
  missing-glyph box.

### Delete CGM, then add back
- Delete now remembers that one sensor (name, type, code, peripheral ID) in UserDefaults
  (`com.loopkit.Loop.directConnect.lastSensor`) and keeps its Keychain key. Setup offers
  "Reconnect to <name>", which starts a manager following that sensor (short authentication;
  full pairing with the stored code if the key is refused). Only one sensor is remembered:
  remembering or pairing a different sensor erases the older key (`DirectConnect_LastSensorStore`).
- Pairing a new sensor also erases the previous sensor's key, so old keys do not accumulate.
- Delete calls `shutDown()`: no scan, discovery or reconnect after it. A plain disconnect used to
  rescan 2 seconds later while the deleted manager was still alive.
- Not yet tested on a phone: both the old and new manager briefly own a CBCentralManager with the
  same restore identifier.

### Add CGM entry
- The list uses its own title without the bolt (`pickerTitle`); with the purple color the sheet
  drew the emoji as a missing-glyph box. Centered with the private `titleTextAlignment` key,
  set only when present; `DirectConnect_PickerStyleTests` fails if a future iOS drops either key.

### Always in the Add CGM list
- DirectConnect is listed in Add CGM even while its switch is off. Choosing it sets
  `DirectConnect_FeatureFlags.isEnabled = true` (in `setupViewController`), so the switch in
  Settings → PowerPack → DirectConnect turns on. Before, the switch had to be on first and
  Settings reopened.

### Last sensor contact under the main-screen CGM pill
- When DirectConnect is the CGM, a small grey line under the pill reads "Last sensor ♥ today @ 1:33p"
  (red heart), vertically centered between the pill and the next block
  (`latestConnect`; "yesterday @", "Oct 7 @", or "none yet"). It moves below the sensor-life bar
  when that bar shows (last 48 h, grace period, expired).
- `LoopUI/Views/DeviceStatusHUDView.swift`: new `footnote` (attributed string, nil hides it).
  `StatusTableViewController.swift` sets it from `DirectConnect_G7CGMManager.hudFootnote`.
  Wording: `DirectConnect_HeartbeatText` (tests in `DirectConnect_StateTests.swift`).
- The line refreshes when the main screen reloads (each reading or Loop cycle), not every minute.

### 2026-10-16 — Pairing a new sensor showed "did not accept the code" for the old sensor
- Device: Pair New Sensor with code 7553 showed "Sensor DXCMSq did not accept the code. Check the
  4 digits on the applicator." DXCMSq was the previous sensor. It refused the new code as
  expected, and Loop skipped it and kept searching, but the screen reported a wrong code.
- Now a refusal during a new-sensor search shows a message that names the skipped sensor and says
  Loop is still searching (`DirectConnect_PairingFailure.skippedSensor`, `DirectConnect_G7Sensor.swift`).
- "Re-enter Pairing Code" is hidden while searching for a new sensor; Pair New Sensor changes the
  code (`DirectConnect_SensorStatusView.swift`).

### 2026-10-16 — New sensor DXCMcw took 20 minutes to pair (diagnostics log)
- The code was correct. From 01:21 to 01:41 UTC the sensor accepted the code-derived key but
  refused the certificate step about 15 times, then paired. It started accepting about 22 minutes
  after the sensor started (warmup 27 minutes). Cause not confirmed.
- Twice the sensor refused to start the code exchange. Loop reported "did not accept the code"
  and skipped the sensor permanently, so from 01:24 to 01:39 Loop did not try it at all, until
  Re-enter Pairing Code emptied the skip list.
- The old sensor DXCMSq was tried twice and refused; it was not the main cause.

Changes:
- A refusal to start the code exchange is no longer reported as a wrong code. It shows a grey status
  line and is retried at the next wake (`.pakeRefused` in `DirectConnect_G7Pairing.swift`).
- A refused certificate step shows a grey status line that says the code was accepted and Loop
  keeps trying (`.certificateRefused`). Grey status lines use `pairingNotice` in
  `DirectConnect_G7State.swift` (not persisted); the red pairing problem is unchanged.
- A sensor that truly refuses the code during a search is skipped for 10 minutes, not
  permanently, and is identified by its Bluetooth ID, not its name (`DirectConnect_SkipList` in
  `DirectConnect_SensorModel.swift`). A scan restarts when the 10 minutes end.
- Pair New Sensor with a code different from the previous sensor's does not connect to the
  previous sensor at all. It is matched by its saved Bluetooth ID, or by name when no ID was saved
  (`DirectConnect_previousSensorToExclude`, `DirectConnect_isExcluded`). After Delete CGM, the
  remembered sensor is used as the previous sensor. The same code still re-pairs the same sensor.
- The previous sensor's code and Bluetooth ID are persisted (`previousPairingCode`,
  `previousPeripheralIdentifier`) so a search resumed after an app restart keeps the exclusion.
- Test changed on purpose: `testWrongCodeRejectionDoesNotPersistKey` became
  `testPakeRefusalIsNotACodeRejectionAndDoesNotPersistKey` (expects `.pakeRefused`). The real
  wrong-code case stays covered by `testFullBootstrapAuthRejectionReportsCodeRejected`.

### Open items
- Run `DirectConnect_*` tests in Xcode.
- Device checks: reading every 5 min and Loop runs; locked phone / background; gap fill after
  being out of range; reconnect after force-quit without re-entering the code; alarms fire;
  Urgent Low audible on silent (Loop lacks Apple's Critical Alerts permission).
- iOS 15 differences: "Re-enter Pairing Code" alert shows no text field (Pair New Sensor still
  works); sensor SF Symbol is blank.
- Commit, then Option B installer support (plan Task 16).
