# LoopInsights — Developer Guide

## Architecture

LoopInsights is the largest PowerPack feature by file count and surface area. It is structured around a `LoopInsights_Coordinator` singleton that owns the AI service stack, the suggestion store, the chat / behavior / debrief / advisor services, and the background monitor. UI surfaces (Dashboard, Settings, Chat, etc.) are SwiftUI views backed by view models that observe the coordinator.

LoopInsights reads from Loop's existing data stores — `GlucoseStore`, `DoseStore`, `CarbStore`, `StoredSettings` — through their public protocols. No LoopKit modifications.

The feature also hosts the **DataLayer** sub-system, which has its own architecture doc at [`../DataLayer/DataLayer_DEVELOPER.md`](../DataLayer/DataLayer_DEVELOPER.md). Most LoopInsights surfaces (Behavior Insights, Meal Debrief, Pre-Meal Advisor, Caregiver Digest, Endo Report) read from DataLayer's local SQLite store rather than re-querying Loop directly.

## File map

```
Loop/
├── Models/LoopInsights/
│   ├── LoopInsights_Models.swift                  // Core types, enums, suggestion shapes
│   ├── LoopInsights_SuggestionRecord.swift        // Persisted suggestion log entry
│   ├── LoopInsights_MealDebriefModels.swift       // Prediction snapshot + debrief shapes
│   ├── LoopInsights_MFPModels.swift               // MyFitnessPal import shapes
│   └── LoopInsights_Phase5Models.swift            // Caffeine, alcohol, goals
├── Resources/LoopInsights/
│   ├── LoopInsights_FeatureFlags.swift            // All runtime toggles
│   └── TestData/                                   // Bundled JSON fixtures (developer-only)
├── Services/LoopInsights/
│   ├── LoopInsights_AIAnalysis.swift              // Builds prompts, parses responses
│   ├── LoopInsights_AIServiceAdapter.swift        // Provider-agnostic HTTP client
│   ├── LoopInsights_AdvancedAnalyzers.swift       // Pattern detection algorithms
│   ├── LoopInsights_DataAggregator.swift          // Reads stores, computes summary stats
│   ├── LoopInsights_BackfillDetector.swift        // Detects historical data gaps
│   ├── LoopInsights_BehaviorInsightsAnalyzer.swift // On-device pattern engine
│   ├── LoopInsights_FoodResponseAnalyzer.swift    // Per-meal glucose response analysis
│   ├── LoopInsights_MealDebriefService.swift      // Prediction snapshot + 2h follow-up
│   ├── LoopInsights_PreMealAdvisorService.swift   // Personal Insight card generator
│   ├── LoopInsights_CaregiverDigestService.swift  // Email/iMessage digest builder
│   ├── LoopInsights_ReportGenerator.swift         // Endo PDF generation
│   ├── LoopInsights_ChatHistoryStore.swift        // Persisted chat transcripts
│   ├── LoopInsights_VoiceService.swift            // TTS via AVSpeechSynthesizer
│   ├── LoopInsights_HealthKitManager.swift        // Biometrics fetcher (HR, HRV, steps, etc.)
│   ├── LoopInsights_NightscoutImporter.swift      // Optional Nightscout backfill
│   ├── LoopInsights_MFPImporter.swift             // MyFitnessPal CSV import
│   ├── LoopInsights_CaffeineTracker.swift         // Half-life decay model
│   ├── LoopInsights_AlcoholTracker.swift          // Linear metabolism + hypo risk
│   ├── LoopInsights_GoalStore.swift               // TIR / A1C goals
│   ├── LoopInsights_GlucoseUnitContext.swift      // mg/dL ↔ mmol/L boundary handler
│   ├── LoopInsights_TestDataProvider.swift        // JSON fixture loader (developer-only)
│   ├── LoopInsights_SecureStorage.swift           // Keychain wrapper for API key
│   └── LoopInsights_SuggestionStore.swift         // Persisted suggestion lifecycle log
├── View Models/LoopInsights/
│   ├── LoopInsights_DashboardViewModel.swift      // Main observable, orchestrates analysis
│   ├── LoopInsights_ChatViewModel.swift           // Ask Loopy state + dictation logic
│   └── LoopInsights_MealInsightsViewModel.swift   // Meal Insights cards
├── Views/LoopInsights/
│   ├── LoopInsights_DashboardView.swift           // Primary entry view
│   ├── LoopInsights_SettingsView.swift            // All LoopInsights configuration
│   ├── LoopInsights_SuggestionDetailView.swift    // Single suggestion detail
│   ├── LoopInsights_SuggestionHistoryView.swift   // Scrollable suggestion log
│   ├── LoopInsights_BehaviorInsightsView.swift    // Pattern detection surface
│   ├── LoopInsights_MealInsightsView.swift        // Per-meal cards with bolus split
│   ├── LoopInsights_MealDebriefCard.swift         // 2h follow-up card
│   ├── LoopInsights_PreMealAdvisorCard.swift      // Personal Insight card (used in FoodFinder)
│   ├── LoopInsights_CaregiverDigestView.swift     // Recipient + cadence config
│   ├── LoopInsights_EndoReportView.swift          // PDF generator UI
│   ├── LoopInsights_ChatView.swift                // Ask Loopy chat
│   ├── LoopInsights_ChatHistoryView.swift         // Past transcripts
│   ├── LoopInsights_TrendsInsightsView.swift      // Time-of-day variance + trend graphs
│   ├── LoopInsights_AGPChartView.swift            // Ambulatory Glucose Profile chart
│   ├── LoopInsights_GoalsView.swift               // TIR / A1C goal config
│   ├── LoopInsights_CaffeineLogView.swift         // Caffeine entry + decay graph
│   ├── LoopInsights_AlcoholLogView.swift          // Alcohol entry + risk graph
│   └── LoopInsights_MonitorSettingsView.swift     // Background monitor config
└── Managers/LoopInsights/
    ├── LoopInsights_Coordinator.swift             // Singleton, lifecycle, service registry
    └── LoopInsights_BackgroundMonitor.swift       // BGTask scheduler + analysis runner

LoopTests/LoopInsights/
├── LoopInsights_ModelsTests.swift
├── LoopInsights_SuggestionStoreTests.swift
└── LoopInsights_DataAggregatorTests.swift

Documentation/LoopInsights/
├── LoopInsights_README.md                         // User guide
└── LoopInsights_DEVELOPER.md                      // This file
```

Total: 35+ Swift files in the LoopInsights namespace. The DataLayer sub-system adds another 13.

## Existing Loop files modified

| File | Diff size | Why |
|---|---|---|
| `Loop/Views/SettingsView.swift` | ~8 lines | Adds `loopInsightsSettingsRow` NavigationLink (feature-flag-gated) |
| `Loop/Views/CarbEntryView.swift` | minor | Hosts `LoopInsights_PreMealAdvisorCard` when FoodFinder result has a familiar match |

LoopKit fork (`taylorpatterson-T1D/LoopKit`):
| File | Diff size | Why |
|---|---|---|
| `LoopKit/LoopUI/Views/TherapySettingsView.swift` | ~5 lines | Therapy help link surface (uses static `TherapyHelpRegistry` set from Loop side) |

## Coordinator boot sequence

```
LoopAppManager launch
  └─→ LoopInsights_Coordinator.shared (lazy init)
       ├── Loads feature flags
       ├── Resolves API key from keychain
       ├── Wires LoopInsights_BackgroundMonitor (no-op if disabled)
       ├── Wires NotificationCenter observers for cross-feature events
       └── Configures TherapyHelpRegistry.destination on parent view's onAppear
                (so navigating into TherapySettingsView resolves the help destination)
```

## Apply modes

`LoopInsights_FeatureFlags.applyMode` ∈ `.manual | .oneTap | .preFill | .auto`. Behavior matrix:

| Mode | What "Apply" does |
|---|---|
| `.manual` | Closes the suggestion sheet. User navigates to Therapy Settings manually. |
| `.oneTap` | Calls `SettingsManager.write(...)` after a confirmation alert with a disclaimer. |
| `.preFill` | Pushes Loop's `TherapySettingsEditor` with the proposed values pre-filled. User confirms or edits. |
| `.auto` | (developer-only) Calls `SettingsManager.write(...)` directly when `confidence ≥ 0.85` and `magnitude ≤ 0.15`. |

Every applied suggestion is logged to `LoopInsights_SuggestionStore` with before/after snapshots. Reverts are first-class — every Apply has a one-tap "Revert" within 24 hours.

## AI Therapy Suggestion flow

```
User taps Analyze
  └─→ DashboardViewModel.runAnalysis(period: lookback)
       ├── DataAggregator.fetch(period:)
       │    ├── Reads GlucoseStore, DoseStore, CarbStore, StoredSettings
       │    └── Computes summary stats (TIR, mean glucose, hourly insulin avg, etc.)
       ├── AIAnalysis.buildPrompt(stats:, currentSettings:)
       ├── AIServiceAdapter.analyze(prompt:) → response JSON
       ├── AIAnalysis.parseResponse(json:) → [LoopInsightsSuggestion]
       ├── Suggestions filtered by guardrails:
       │    ├── ±20% magnitude cap
       │    ├── Basal blocked unless CR stable ≥7 days
       │    └── ISF blocked unless CR + Basal stable ≥3 days
       ├── SuggestionStore.append(...) for audit trail
       └── DashboardView renders cards
```

Prompt size stays roughly constant regardless of lookback period because data is aggregated to summary stats before sending. A 90-day analysis sends the same prompt size as a 14-day analysis — only the underlying numbers differ.

## Behavior Insights

`LoopInsights_BehaviorInsightsAnalyzer` runs on-device against the local DataLayer event store. No AI call. Patterns are typed (`BehaviorPattern` enum) with confidence scores and supporting event counts. Renders in `LoopInsights_BehaviorInsightsView`.

Pattern producers live in `LoopInsights_AdvancedAnalyzers.swift`:
- `analyzeFoodFinderCorrections()` — meals where user overrode AI carb estimate
- `analyzeBolusProAdoption()` — slider drift, auto-detect override rate
- `analyzeOverrideUsage()` — preset adoption + glucose response
- `analyzeTimeOfDayVariance()` — hourly TIR breakdown
- `analyzeCaffeineCorrelations()` — glucose response 1-3h after caffeine log
- `analyzeAlcoholCorrelations()` — glucose response 4-12h after alcohol log

Min event count for any pattern: 5. Confidence threshold for surfacing: 0.6.

## Meal Debrief

`LoopInsights_MealDebriefService.captureSnapshot(forMeal:)` is invoked from a NotificationCenter listener on `.foodFinderMealLogged`. It writes a `PredictionSnapshot` containing the predicted glucose curve at meal time + meta about the dose.

A second listener fires 2 hours later (via `Timer` if foreground, BGTask if backgrounded) and runs `generateDebrief(forSnapshotID:)`:
- Reads actual CGM trace from snapshot time + 2h
- Computes peak time, peak magnitude, AUC delta vs. predicted
- Surfaces "Effective carbs estimate" using observed AUC / user's CR
- Writes `MealDebrief` record with 90-day retention

Both stores live in JSON files under `Documents/LoopInsights/`.

## Pre-Meal Advisor

`LoopInsights_PreMealAdvisorService` matches an incoming `FoodFinder_NutritionResult` against `MealDebrief` history by name + venue + macro fingerprint. When ≥2 matches, it produces a `PreMealAdvice` payload (typical peak, time-to-peak, suggested portion adjustment, suggested pre-bolus minutes) which `LoopInsights_PreMealAdvisorCard` renders inside FoodFinder.

## Caregiver Digest

`LoopInsights_CaregiverDigestService` builds a digest payload from the last 24h or 7d of DataLayer events:
- TIR + mean glucose
- Notable lows / highs
- Recent boluses by type
- Recent meals by name
- Therapy changes since last digest

Renders as plain-text (iMessage) or HTML (email). Sent via `MFMailComposeViewController` / `MFMessageComposeViewController` — PowerPack never holds digest contents in transit.

## Endo Report

`LoopInsights_ReportGenerator` uses `PDFKit` to compose a multi-page PDF:
- Cover page with date range + generation timestamp
- AGP chart (rendered via `LoopInsights_AGPChartView` exported to UIImage)
- TIR table by week
- Dose patterns by hour
- Therapy settings change log
- Recent suggestion lifecycle (generated / applied / reverted)

PDF stays in `Documents/LoopInsights/` until shared. Default retention: 30 days, then auto-pruned.

## Ask Loopy

`LoopInsights_ChatViewModel` manages dictation + send + TTS. Key behaviors:
- Dictation detection via `.onChange(of: inputText)` — a 4+ char burst is treated as dictation, a 1-char delta is typing.
- Auto-send fires 2 seconds after dictation pause.
- Voice-initiated messages get a spoken response via `AVSpeechSynthesizer`. Tap "Listen" on any past assistant bubble to replay.
- Send button swaps to a stop button during TTS playback.
- Transcript persisted via `LoopInsights_ChatHistoryStore`.

Context window is composed of summary stats + recent meals + recent boluses + recent suggestions, NOT raw event history. Prompt size stays bounded.

## Background Monitor

`LoopInsights_BackgroundMonitor` schedules `BGTaskScheduler` tasks at user-configured intervals (off / daily / 12h / 6h). Each fire:
- Runs `analyzeRecentEvents()`
- If a high-confidence pattern emerges (e.g. 5 consecutive over-bolused meals at lunch), posts a UNNotification
- Updates the monitor settings UI with last-fire timestamp + result

Off by default. Status surface in `LoopInsights_MonitorSettingsView`.

## Glucose units

`LoopInsights_GlucoseUnitContext` is the single source of truth for mg/dL vs. mmol/L formatting. Internally everything is mg/dL (matching LoopKit conventions). Conversion happens at the display boundary and at the AI prompt boundary — the prompt always sends values in the user's display unit so the AI's narrative matches the user's mental model.

See `Documentation/LoopInsights/glucose_units.md` (project memory) for the full convention.

## Therapy Help registry

LoopInsights renders help destinations inside LoopKit's `TherapySettingsView` (a LoopKit-side view). Direct injection via SwiftUI `@Environment` was unreliable across NavigationLink boundaries (project memory: "value was always nil despite correct `.environment()` setup").

Workaround: a static `TherapyHelpRegistry.destination` property is set from `LoopInsights_SettingsView.onAppear` (Loop-side) and read from `TherapySettingsView` (LoopKit-side). The `.onAppear` timing matters — set it on the parent view, not on `TherapySettingsView` itself, because parent's `.onAppear` fires before child renders.

## Test Data fixtures (developer-only)

`LoopInsights_TestDataProvider` loads JSON fixtures instead of reading live data stores. Useful for development, demos, and evaluating LoopInsights without waiting for real data accumulation.

### Fixture locations (checked in order)

1. **App Documents** — `Documents/LoopInsights/` (no rebuild needed)
2. **App Bundle** — `Resources/LoopInsights/TestData/` (requires rebuild)

### Expected fixture filenames

- `tidepool_glucose_samples.json` — CGM glucose readings (`StoredGlucoseSample` format)
- `tidepool_dose_entries.json` — Insulin deliveries (`DoseEntry` format)
- `tidepool_carb_entries.json` — Carb entries (`StoredCarbEntry` format)
- `tidepool_therapy_settings.json` — Therapy settings (optional)

### Enabling Test Data Mode

1. Open Settings → LoopInsights
2. Long-press the LoopInsights header **5 times** to unlock Developer Mode
3. Scroll to the Developer section
4. Toggle **Use Test Data Fixtures** on
5. Open the Dashboard and run an analysis

### Generating fixtures from Tidepool

`Scripts/pull_tidepool_data.py` pulls real diabetes data from a Tidepool account and converts it into the fixture format LoopInsights expects.

```bash
pip3 install requests

# Pull 14 days (default)
python3 pull_tidepool_data.py --email YOUR_EMAIL --password YOUR_PASSWORD

# Pull 90 days
python3 pull_tidepool_data.py --email YOUR_EMAIL --password YOUR_PASSWORD --days 90

# Auto-copy to Simulator
python3 pull_tidepool_data.py --email YOUR_EMAIL --password YOUR_PASSWORD --simulator
```

The script:
1. Authenticates with `api.tidepool.org`
2. Pulls CGM glucose, insulin doses, carb entries, pump settings
3. Converts Tidepool format → Loop's native JSON format
4. Saves to `Loop/Resources/LoopInsights/TestData/`
5. With `--simulator`, copies into the most-recent iOS Simulator's `Documents/LoopInsights/`

### Manual fixture format

If you don't have Tidepool access, create fixtures by hand:

**`tidepool_glucose_samples.json`**:
```json
[
  { "startDate": "2026-02-01T08:00:00Z",
    "quantity": 120.0,
    "provenanceIdentifier": "com.test",
    "syncIdentifier": "sample-001",
    "syncVersion": 1,
    "isDisplayOnly": false,
    "wasUserEntered": false }
]
```

**`tidepool_dose_entries.json`**:
```json
[
  { "type": "tempBasal",
    "startDate": "2026-02-01T08:00:00Z",
    "endDate":   "2026-02-01T08:30:00Z",
    "value": 0.85, "unit": "U/hour", "automatic": true },
  { "type": "bolus",
    "startDate": "2026-02-01T12:00:00Z",
    "endDate":   "2026-02-01T12:01:00Z",
    "value": 3.5, "unit": "U", "isMutable": false }
]
```

**`tidepool_carb_entries.json`**:
```json
[
  { "startDate": "2026-02-01T12:00:00Z",
    "quantity": 45,
    "absorptionTime": 10800,
    "syncIdentifier": "carb-001",
    "syncVersion": 1,
    "createdByCurrentApp": false }
]
```

**`tidepool_therapy_settings.json`** (optional):
```json
{
  "basalRateSchedule": [
    { "startTime": 0,     "value": 0.8 },
    { "startTime": 21600, "value": 0.9 }
  ],
  "insulinSensitivitySchedule": [
    { "startTime": 0,     "value": 45 },
    { "startTime": 21600, "value": 40 }
  ],
  "carbRatioSchedule": [
    { "startTime": 0,     "value": 10 },
    { "startTime": 21600, "value": 8 }
  ]
}
```

`startTime` is seconds from midnight (21600 = 6:00 AM, 43200 = 12:00 PM).

### Loading fixtures on a physical device

1. Connect device to Mac
2. Finder → device → Files tab
3. Drag the four JSON files into the **Loop** app's Documents folder under a `LoopInsights/` subfolder
4. Enable Test Data mode in Developer settings

`TestDataProvider` checks `Documents/LoopInsights/` first, so user-provided files always take priority over bundled fixtures.

## Known limitations / V2 backlog

- **AI suggestions are LLM-based.** See MANIFESTO.md — the long-term destination is a true ML model (likely Pre-Meal Advisor first) trained on DataLayer events.
- **Background monitor uses `BGTaskScheduler`.** Subject to iOS's aggressive throttling. Reliability varies by device usage patterns.
- **No multi-user / multi-profile.** One LoopInsights install = one person's data. Caregiver-mode (read-only access to a child's data) is on the V2 backlog.
- **Endo Report PDF format is fixed.** No template customization in v1.
- **Goals are simple.** TIR + A1C only. Per-time-of-day or per-day-of-week goals are V2.
