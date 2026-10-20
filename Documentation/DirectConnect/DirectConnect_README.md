# DirectConnect

**PowerPack Exclusive.** Loop pairs directly with Dexcom G7, Dexcom ONE+ and Dexcom Stelo
sensors. The Dexcom app is not needed.

## What it does

- Pairs with a new sensor using the 4-digit code printed on its applicator.
- Receives a glucose reading about every 5 minutes. Each reading also wakes Loop, so Loop runs
  on every reading.
- Fills in readings missed while the phone was out of range, from the sensor's own history.
- Calibrates the sensor with a fingerstick value (optional; most sensors are factory calibrated).
- Reads the sensor's session length and warmup time from the sensor after pairing and shows them
  on the sensor screen. There is nothing to set.
- Raises its own glucose alarms (below).
- Takes the sensor back automatically if another app (usually the Dexcom app) pairs with it.
- Shows sensor details, days left, the pairing code, and a diagnostics screen with connection
  reliability counts.

## Turning it on

1. Settings → Add CGM (or tap **Add CGM** at the top of the main screen) → **Dexcom G7/ONE+ using
   DirectConnect** (purple). Stelo sensors use the same entry. Choosing it also switches on
   Settings → PowerPack → DirectConnect.
2. Choose the sensor type, enter the code from the applicator, tap **Pair Sensor**.
3. Keep the phone near the sensor. Pairing completes at the sensor's next wake (up to 5 minutes).
   The G7 warmup period then runs before readings start.

The switch cannot be turned off while DirectConnect is your CGM. Delete the CGM first
(Settings → CGM → DirectConnect → Delete CGM).

**Deleting and adding back.** Delete CGM stops all DirectConnect Bluetooth activity and remembers
that one sensor: its name, code and saved pairing. When you add DirectConnect again, setup shows
**Reconnect to DXCM…** with the code; tap it to reconnect at the sensor's next wake, without the
applicator. Loop remembers only the last sensor; pairing a different sensor erases the remembered
one and its saved pairing.

## Changing sensors

The sensor screen shows a "What to do now" tip for the sensor's current state, and a "How to
change your sensor" guide that opens automatically once the sensor is in its grace period, ended, or
failed.

1. Insert the new sensor (allowed during the old sensor's 12-hour grace period).
2. Note the new applicator's 4-digit code before discarding it. Each sensor has its own code.
3. Settings → CGM → DirectConnect → **Pair New Sensor**; choose the type, enter the new code.
   Loop stops using the old sensor when you tap the button.
4. Keep the phone near the sensor; pairing finishes within about 5 minutes.
5. Wait for warmup; the sensor screen shows when readings will start. No glucose in Loop
   during warmup.
6. Remove the old sensor once the new one shows readings.

## Before you start

- **Only one app can own the sensor.** DirectConnect can take over a sensor already running in the
  Dexcom app: pair it with the same applicator code. Delete the Dexcom app (or remove the sensor
  from it) afterwards. If the Dexcom app pairs with the sensor again, DirectConnect re-pairs at the
  next sensor wake, but each takeover costs readings, and the sensor screen warns you when it
  keeps happening.
- **Dexcom app alerts** are replaced by DirectConnect alarms (below).

## What you don't get with DirectConnect

| Dexcom app feature | With DirectConnect | Use instead |
|---|---|---|
| **Dexcom Clarity** reports | Not available. Only the Dexcom app can upload to Clarity, through Dexcom's private connection. Dexcom's public developer service only lets approved apps read readings, not send them. | **Tidepool.** Settings → Services → Tidepool. Loop uploads glucose, insulin and carbs, and Tidepool produces CGM reports (time in range, average glucose, daily patterns) similar to Clarity's. Many clinics accept Tidepool reports. |
| **Dexcom Share** / Dexcom Follow app | Not available. Loop has no supported way to send readings to Share. | **Nightscout** or **LoopFollow.** Settings → Services → Nightscout uploads glucose, insulin and carbs; followers watch them in a web browser, the Nightscout app, or the LoopFollow app, with their own alarms. |

**Apple Health is not lost.** Loop saves DirectConnect readings to Apple Health (source: Loop,
device "PowerPack DirectConnect") when Loop has write permission. Check in the Health app → Browse
→ Vitals → Blood Glucose → Data Sources & Access.

The **Upload Readings** switch on the sensor screen controls whether DirectConnect readings go to
Tidepool and Nightscout. Leave it on to use the services above.

## Alarms

Settings → PowerPack → DirectConnect → Glucose Alarms (also from the sensor screen).

| Alarm | Default | You can change |
|---|---|---|
| Urgent Low | below 55 mg/dL, repeats every 5 min | on/off (with confirmation), 40–70 mg/dL, 5–30 min |
| Low | below 70 mg/dL, repeats every 15 min | on/off, 55–100 mg/dL, 5–60 min |
| High | above 250 mg/dL, repeats every 60 min | on/off, 120–400 mg/dL, 15–240 min |
| Falling Fast | 3 mg/dL/min, once per episode | on/off, 2–5 mg/dL/min |
| Rising Fast | off | on/off, 2–5 mg/dL/min |
| Signal Loss | 20 min without a reading | on/off, 10–60 min |
| Sensor Expiring | 24 h and 2 h before the end | on/off |
| Sensor Ended or Failed | when the sensor stops | on/off |

**Sound, silent switch and Focus:** every alarm shows a notification. Apple lets only approved
apps send notifications that sound on silent, and Loop builds are not approved, so Loop also plays
each alarm's sound itself:

- **Play Through Silent** (each alarm): on plays the alarm even with the phone on
  silent, in a Focus, or with Loop's **Mute Alerts** on. Off follows the phone's settings, so the
  alarm makes no sound on silent. It is **on by default for Urgent Low and Falling Fast** (turning
  it off asks for confirmation) and off for the others.
- **Urgent Low and Falling Fast** repeat their sound until you open Loop, press OK, or glucose
  leaves the alarm range. Their sound can be changed but not set to None. Other alarms play their
  sound three times; **None (vibrate only)** turns an alarm's sound off.
- **Sound** opens a list: Loop's four tones (Siren, Alarm Clock, Pulse, Chime) and the 117 sounds
  from xDrip4iOS. Tapping a sound in the list selects it and plays it for 6 seconds, as in iOS
  Settings → Sounds; the list stays open. The **Volume** slider at the top of the list (default
  40%) sets that alarm's loudness: while the alarm sounds, Loop sets the phone's media volume to
  that level and puts it back afterwards, so the alarm does not depend on the volume the phone was
  left at. Moving the slider replays the sound at the new level. **Test Sound** plays the alarm for 6 seconds with the same rules it uses at
  night. With a non-urgent alarm, an xDrip4iOS sound (up to 30 seconds) plays once.

Loop can play a sound only while iOS keeps Loop running. If iOS has closed Loop, no sensor readings
arrive and no alarm can fire. Test Urgent Low with the phone locked and on silent before relying
on it.

## Sensor screen

- **Days left:** small grey text under the status bar: "9 days left", then hours on the last day,
  then the time left in the 12-hour grace period.
- **Pairing Code:** the 4-digit code last entered, under the sensor name.
- **Upload Readings:** on (default) sends this sensor's readings to the services set up under
  Settings → Services, such as Nightscout or Tidepool. Off keeps them on the iPhone; Loop still
  uses them for dosing, alarms and Apple Health. DirectConnect never uploads to Dexcom Clarity or
  Dexcom Share.

## Calibration

Sensor screen → **Calibrate**. Enter a fresh fingerstick value. It is sent at the next sensor
connection (within about 5 minutes). The status shows Queued → Sent → Processing → Completed, or
the reason the sensor rejected it. Values older than 5 minutes are not sent.

A line under the status says what is happening to your value: while Queued, that it is waiting for
the next connection; while Processing, the time the sensor accepted it. The text under the entry
box is a fixed explanation of how calibration works, not the status of your value.

- A new value can be entered while an earlier one still shows Processing; the new one replaces it.
- Processing ends after 30 minutes at most. If the sensor never confirmed the value, the status
  reads "Sent. The sensor did not report whether it used the value."
- **Last Successful Calibration** shows the most recent value the sensor confirmed, and when the
  fingerstick was taken. It resets when you pair a new sensor.
- Do not calibrate while the sensor reports a temporary sensor issue.

## Troubleshooting

| Message | Meaning | What to do |
|---|---|---|
| "Sensor DX… did not accept the code" | The code was wrong, or a nearby sensor that is not yours refused it | Check the 4 digits; Loop keeps looking for your sensor |
| "Pairing lost" | The saved key was refused; another app may own the sensor | Remove the sensor from the other app, then Re-enter Pairing Code |
| "Waiting for sensor" | Normal between wakes | Wait up to 5 minutes |
| No readings after pairing | Warmup in progress | Wait for warmup to finish |
| "Temporary sensor issue" | The sensor is connected but is withholding a value it does not trust | Readings usually return on their own; check with a fingerstick meanwhile |
| "The sensor is sending Loop only an old reading" | Another app paired with the sensor, or the sensor failed | Loop re-pairs automatically; delete the Dexcom app |

Diagnostics (sensor screen → Diagnostics) shows:

- **Connection Health** for the last 24 hours and 7 days: wakes received of expected (green at 98%
  or more), readings withheld by the sensor, old cached readings, missed wakes, number of gaps,
  longest gap, take-backs and pairing failures.
- Firmware, signal strength, saved-key status and the recent communication log, including every
  calibration message to and from the sensor.
- **Copy Diagnostics** (confirms with a check mark), **Share Diagnostics**, and **Clear Logs**
  (asks first; clears the log and the Connection Health counts, not the pairing).

Send Copy Diagnostics, not the Xcode console, when reporting a problem: the console contains
service login tokens; Copy Diagnostics does not.

## Credits

DirectConnect's core, the sensor pairing and communication with G7-family sensors, is based on
**xDrip4iOS**, created by **Johan Degraeve** and developed with the xDrip4iOS contributors
(https://github.com/JohanDegraeve/xdripswift). Thank you. Without their work, DirectConnect would
not exist.

Also used: LoopKit's G7SensorKit (MIT) for the CGM manager structure, and micro-ecc by Kenneth
MacKay (BSD-2-Clause) for the P-256 arithmetic. The 117 xDrip4iOS alarm sounds come from
xDrip4iOS, which took most of them from the Spike project.

## License

DirectConnect contains code derived from xDrip4iOS, licensed under the GNU GPL version 3. Builds
of PowerPack that include DirectConnect are distributed under the GPL-3.0 terms for that code. See
`Loop/Managers/DirectConnect/LICENSE-GPL-3.0.txt` for the notice and the list of derived files.

DirectConnect is DIY software, not approved by any regulatory body. The disclaimers that apply to
Loop apply here.
