# LoopInsights

**AI-powered analysis, behavior insights, and care-team reporting on top of Loop.**

## What it does

LoopInsights reads your glucose, insulin, carbs, and (optionally) HealthKit biometrics, then surfaces a set of decision-support tools:

- **AI Therapy Suggestions.** Proposes adjustments to Carb Ratio (CR), Insulin Sensitivity Factor (ISF), and Basal Rate schedules. You review and apply.
- **Behavior Insights.** Local pattern detection across your meals, boluses, presets, FoodFinder corrections, BolusPro slider drift, and more. No AI calls — runs on-device.
- **Meal Debrief.** Captures predicted vs. actual glucose response after every FoodFinder meal and reports back two hours later.
- **Pre-Meal Advisor.** When you're about to log a familiar food, surfaces your typical post-meal response and suggests a portion or pre-bolus adjustment.
- **Ask Loopy Chat.** Conversational AI tuned on your recent data. Voice in, voice out, transcript saved.
- **Caregiver Digest.** Daily or weekly summary email/iMessage to a care partner.
- **Endo Visit Report.** One-tap PDF for your endocrinologist appointment, covering Time in Range, dose patterns, and recent therapy changes.
- **Caffeine and Alcohol Trackers.** Manual logs with on-device metabolism models that surface as context in Behavior Insights and Ask Loopy.
- **Goals.** Set Time-in-Range or A1C-style targets and watch trend.
- **DataLayer.** The local SQLite event store powering all of the above. See [DataLayer_README](../DataLayer/DataLayer_README.md).

LoopInsights runs on a **bring-your-own API key** model. The same Keychain entry is shared with FoodFinder.

## How to use it

1. **Enable LoopInsights** in Settings → LoopInsights. (Master toggle is OFF by default.)
2. **Configure your AI provider** — pick Claude / OpenAI / Gemini and paste your API key.
3. **Open the Dashboard** from Settings → LoopInsights → Dashboard.
4. **Tap Analyze.** First analysis takes ~5-30 seconds depending on lookback period and AI provider.
5. **Review the suggestion cards.** Each shows current value, proposed value, confidence, and time-blocks affected.
6. **Apply or dismiss.** Apply behavior depends on your Apply Mode (see below).

After the first run, the rest of the surfaces (Behavior Insights, Meal Debrief, etc.) start populating as you log meals and Loop runs.

## AI Therapy Suggestions

The CR / ISF / Basal advisor is the original LoopInsights surface. It analyzes a configurable lookback window (3 / 7 / 14 / 30 / 90 days) of your glucose, insulin, and carb data and proposes adjustments.

**Guided tuning order:**
1. **Carb Ratio first** — most impact on post-meal variability.
2. **ISF second** — affects correction doses.
3. **Basal Rate last** — affects the entire 24-hour profile.

LoopInsights will refuse to suggest Basal changes until your CR has been stable for ≥7 days. The "one thing at a time" guardrail is intentional. Changing CR + ISF + Basal in the same session makes outcome attribution impossible.

### Apply modes

Settings → LoopInsights → Apply Mode:

| Mode | Behavior |
|---|---|
| **Manual** *(default)* | Shows the suggested values. You navigate to Therapy Settings and edit by hand. |
| **One-Tap Apply** | Writes via SettingsManager after a confirmation disclaimer. |
| **Pre-Fill Editor** | Opens Loop's Therapy Settings editor with the proposed values pre-filled. You confirm or edit. |
| **Auto-Apply** *(developer-only)* | Applies high-confidence suggestions automatically. Hidden behind 5x long-press on the LoopInsights header. |

Suggestions are capped at **±20%** change from the current value, regardless of mode. Conservative under-adjustment is preferred over aggressive over-adjustment.

## Behavior Insights

Behavior Insights is the local-pattern engine. It reads your DataLayer event store and surfaces patterns like:

- **FoodFinder correction patterns** — meals where you consistently override the AI's carb estimate, with the typical adjustment magnitude.
- **BolusPro adoption + slider drift** — what fraction of high-FPU meals you bolus for, your typical slider position vs. the system default.
- **Override usage** — which presets you activate most and the typical glucose response.
- **Time-of-day variance** — windows where your TIR drops consistently (e.g. dinner is fine, midnight to 4am is not).
- **Caffeine and alcohol correlations** — surfaces glucose response in the hours after a logged caffeine or alcohol entry.

All Behavior Insights run on-device. No AI call, no network egress. They appear in the LoopInsights Dashboard once you have at least 7 days of DataLayer events with the relevant categories enabled.

## Meal Debrief

When FoodFinder logs a meal, LoopInsights captures a snapshot of Loop's predicted glucose curve. Two hours later, it compares the prediction to the actual CGM trace and writes a debrief: how well did the prediction track? Did the meal absorb faster or slower than expected? Was the carb estimate close, or were you correcting late?

Debriefs accumulate and feed Pre-Meal Advisor's suggestions. Browse them in Dashboard → Meal Debriefs.

## Pre-Meal Advisor

A "Personal Insight" card that appears in FoodFinder when you're about to log a meal you've eaten ≥2 times. The card shows:

- Your typical post-meal peak glucose for this meal
- The typical time to peak
- Suggested portion adjustment based on past corrections
- Suggested pre-bolus minutes if late corrections were a pattern

The advisor is gated by `preMealAdvisorEnabled` (default OFF) under Settings → LoopInsights → AI Features.

## Ask Loopy Chat

Conversational AI with awareness of your recent dosing data. Settings → LoopInsights → Ask Loopy.

- **Voice in** — long-press the mic to dictate. Auto-send fires 2 seconds after you stop talking.
- **Voice out** — voice-initiated questions get spoken responses via `AVSpeechSynthesizer`. Tap "Listen" on any past answer to replay.
- **Transcript saved** — full chat history is persisted locally with 90-day retention.
- **Context-aware** — your last N days of data (configurable) are summarized into the prompt. Changes to lookback don't blow up prompt size because data is aggregated to summary stats before sending.

## Caregiver Digest

Settings → LoopInsights → Caregiver Digest.

- Add a recipient (email or iMessage handle).
- Pick a cadence (daily morning, weekly Sunday).
- Pick scope (TIR summary, recent boluses, recent meals, alerts).
- Optionally add a personal note that prepends every digest.

Digests render as plain-text (iMessage) or HTML (email). Sent via `MFMailComposeViewController` / `MFMessageComposeViewController` so iOS handles the actual send.

## Endo Visit Report

One-tap PDF for your endocrinologist appointment. Settings → LoopInsights → Endo Report.

Covers a configurable date range (default: last 90 days):
- Time in Range summary, AGP-style chart
- Dose patterns by hour of day
- Therapy settings changes since last report (CR, ISF, Basal, target ranges)
- Recent BolusPro and FoodFinder usage stats
- Notable AI suggestion lifecycle (generated, applied, reverted)

PDF generated via `PDFKit` on-device. Share via the standard iOS share sheet.

## Caffeine and Alcohol

Settings → LoopInsights → Substances.

Both are manual logs (no HealthKit integration). Each carries a metabolism model:

- **Caffeine:** half-life decay model with peak at 30-45 minutes, surfaced as "current caffeine level" in Behavior Insights.
- **Alcohol:** linear metabolism with delayed-hypo risk window. Standard-drink scale 0-5.

Glucose context for both is read from CGM. Patterns surface in Behavior Insights and Ask Loopy can answer questions like "did my coffee at 9am affect my morning numbers?".

## Goals

Set targets and track progress:
- TIR goal (e.g. 75% in 70-180)
- A1C-equivalent goal (computed from average glucose)
- Custom date range

Goals show on the Dashboard with current vs. target progress.

## Configuring it

Settings → LoopInsights → Settings:

| Setting | Default | What it does |
|---|---|---|
| **Enable LoopInsights** | OFF | Master toggle. Off → no LoopInsights UI in Settings. |
| **AI Provider** | Claude | Pick Claude / OpenAI / Gemini / BYO. |
| **API Key** | (blank) | Pasted to iOS Keychain. Shared with FoodFinder. |
| **Default Analysis Period** | 14 days | Used for Dashboard analysis and Ask Loopy context. |
| **Apply Mode** | Manual | See table above. |
| **Pre-Meal Advisor** | OFF | Enable Personal Insight card in FoodFinder. |
| **Meal Debrief** | OFF | Enable post-meal prediction-vs-actual capture. |
| **Background Monitor** | OFF | Periodic background analysis with notifications for high-confidence patterns. |
| **Developer Mode** | OFF | Long-press the LoopInsights header 5 times to unlock. |

## Privacy

- **Your data goes to your chosen AI provider.** PowerPack does not proxy.
- **API key in iOS Keychain.** Shared with FoodFinder.
- **DataLayer events are opt-in per category.** Behavior Insights + Pre-Meal Advisor + Meal Debrief read from your local DataLayer store. Without DataLayer enabled they have no data.
- **Caregiver Digest is sent via iOS native compose sheets.** PowerPack never sees the contents.
- **Endo Report is generated locally.** PDF stays on your device until you share it via the iOS share sheet.

## Data Sharing (DataLayer)

LoopInsights includes an optional **DataLayer** module that can collect and share anonymized health data for research and provider sharing. **DataLayer is OFF by default and every consent category is OFF by default.** Nothing is collected and nothing is uploaded until you opt in.

A default ingest endpoint is bundled with the AllFeatures build so that opt-in data uploads work out of the box. You can override it with your own endpoint, or leave it blank for local-only collection.

**To enable data sharing:**

1. Open **Settings > LoopInsights**
2. Tap **Data Sharing**
3. Turn on the **Enable Data Sharing** master toggle
4. Toggle the individual categories you want to share (glucose, insulin, carbs, biometrics, AI behavioral, substances, activity)
5. Turn on **Contribute to Research** if you want enabled categories uploaded to the project research backend

All data is stored locally first, retained 90 days, and can be deleted at any time from the Data Sharing screen via the **Delete All My Data** button.

Full documentation: [DataLayer_README.md](../DataLayer/DataLayer_README.md).

---

*LoopInsights is part of Loop (AID) PowerPack. See [LoopInsights_DEVELOPER.md](LoopInsights_DEVELOPER.md) for architecture, file map, and developer notes including Test Data fixtures.*
