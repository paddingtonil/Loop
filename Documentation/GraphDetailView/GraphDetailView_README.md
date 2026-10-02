# GraphDetailView

**Long-press the home-screen glucose chart to inspect any moment in time.**

## What it does

The default Loop home chart shows a glucose trace, but tapping a point gives you only the glucose value. GraphDetailView replaces that with a richer popup. Long-press anywhere on the chart and a card appears showing every data series Loop has at that exact timestamp: glucose, insulin on board, carbs on board, the most recent bolus, the basal rate, the active override preset, the active AutoPresets activity, and your heart rate (if HealthKit has it).

You can drag your finger left or right to scrub through time — the popup updates live as you move. Lift your finger and it auto-fades after 5 seconds.

## How to use it

1. **Open Loop.** GraphDetailView is on by default — there is no setting to enable.
2. **Long-press the glucose chart** (about 0.5 seconds).
3. **The popup appears** at the touched timestamp.
4. **Drag left or right** to scrub through time. The popup follows your finger and refreshes the data behind it.
5. **Lift your finger.** The popup stays visible for ~5 seconds then fades.
6. **Tap anywhere else** to dismiss it immediately.

## Why it's always on

Every other PowerPack feature ships with a master toggle defaulting OFF. GraphDetailView is the exception. It has no algorithm side-effects, no background processing, no network egress, and no data collection beyond a single optional event sent to your local DataLayer (only if you've separately opted in). It's a UI affordance for inspecting data Loop already has on screen. Making it opt-in would just hide a useful debug surface behind a toggle most users would never find.

## What you'll see

| Row | What it means |
|---|---|
| **Glucose** | The CGM value nearest the touched timestamp |
| **IOB** | Insulin on board at that moment |
| **COB** | Carbs on board at that moment |
| **Recent Bolus** | The most recent bolus prior to the timestamp, with the time it was delivered |
| **Basal Rate** | The basal rate Loop was delivering at that moment |
| **Preset** | Active Loop override preset, if any |
| **AutoPreset** | Active AutoPresets-driven preset (e.g. "Walking"), if any |
| **Heart Rate** | HealthKit heart rate sample nearest the timestamp, if HealthKit access is granted |

A row is hidden when the data isn't available (e.g. no preset active, no HealthKit permission).

## Use cases

- **Forensics.** "Why did I spike at 3pm?" Scrub to 3pm and see what bolus, what carbs, what basal rate, and what preset were in play.
- **Comparison.** Drag from the meal time forward and watch IOB and COB rise and fall against the glucose trace.
- **Sanity checks.** Confirm an AutoPreset actually activated when you started walking, by scrubbing to that moment.

## Privacy

- All data shown comes from Loop's local stores (GlucoseStore, DoseStore, CarbStore, OverrideHistory) plus HealthKit.
- Nothing leaves the device.
- A single `graphDetailViewOpened` event is broadcast on every popup appearance for DataLayer ingest. **That event is only recorded if you've separately enabled DataLayer + the Activity & Presets consent category.** Otherwise the broadcast is heard by no one.

---

*GraphDetailView is part of Loop (AID) PowerPack. See [GraphDetailView_DEVELOPER.md](GraphDetailView_DEVELOPER.md) for architecture and developer notes.*
