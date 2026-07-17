# DataLayer — Developer Guide

## Architecture

DataLayer is a local-first event store that other PowerPack features publish into via `NotificationCenter`. The store lives in SQLite under the app's Documents directory. A separate sync service uploads consented events to a configurable HTTP endpoint when the user has opted in.

The decoupling is deliberate. Each feature (BolusPro, FoodFinder, LoopInsights, AutoPresets, GraphDetailView, SiteAtlas) posts named notifications when something happens. `DataLayer_Coordinator` is the only listener. This means a feature's source code never imports DataLayer types, and removing DataLayer from a build wouldn't break any other feature — the notifications would simply have no listener.

```
Feature                       NotificationCenter            DataLayer_Coordinator
   │                                  │                            │
   │── posts                          │── delivers                 │
   │   "foodFinderMealAnalyzed" ────► │ ───────────────────────►   │
   │                                  │                            │
   │   userInfo: {                    │                            ├── consent.isGranted(.carbsAndMeals)? skip if no
   │     foodName, carbsGrams, ...    │                            ├── builds typed payload struct
   │   }                              │                            ├── collector.record(type:, payload:)
                                                                   │      │
                                                                   │      ├── EventStore.insert(...) → SQLite
                                                                   │      └── SyncService picks up next tick
```

## File map

```
Loop/
├── Models/DataLayer/
│   ├── DataLayer_EventModels.swift          // Event enum, payload structs (28 types)
│   └── DataLayer_ConsentModels.swift         // ConsentCategory enum, ConsentRecord
├── Resources/DataLayer/
│   └── DataLayer_FeatureFlags.swift         // Master toggle, retention, endpoint URLs
├── Services/DataLayer/
│   ├── DataLayer_EventCollector.swift       // Public record(type:payload:) entry point
│   ├── DataLayer_EventStore.swift           // SQLite wrapper, prune/insert/query
│   ├── DataLayer_ConsentManager.swift       // Per-category consent state + audit log
│   ├── DataLayer_SyncService.swift          // Background uploader, retry/backoff
│   ├── DataLayer_ProviderProtocol.swift     // Protocol for pluggable upload backends
│   ├── DataLayer_ReportGenerator.swift      // PDF / share-link generation
│   └── DataLayer_SecureStorage.swift        // Keychain wrapper, anonymized device ID
├── Managers/DataLayer/
│   └── DataLayer_Coordinator.swift          // Singleton, lifecycle, all feature listeners
└── Views/DataLayer/
    ├── DataLayer_ConsentView.swift          // 7-category consent UI + master toggle
    └── DataLayer_DashboardView.swift        // Local debug view: event counts, recent events

Documentation/DataLayer/
├── DataLayer_README.md                      // User guide
└── DataLayer_DEVELOPER.md                   // This file
```

Plus one BolusPro-specific bridge file at `Loop/Services/BolusPro/BolusPro_DataLayerHook.swift`, which lets BolusPro post a typed snapshot via NotificationCenter without importing any DataLayer types.

## Existing Loop files modified

| File | Diff size | Why |
|---|---|---|
| `Loop/Managers/LoopAppManager.swift` | +3 lines | Calls `DataLayer_Coordinator.shared.start()` after Loop launch |
| `Loop/View Controllers/StatusTableViewController.swift` | +5 lines | Calls `DataLayer_Coordinator.shared.configureStores(...)` after stores are ready |

Total: 8 lines across 2 existing Loop files.

## Defaults are OFF

`DataLayer_FeatureFlags.registerDefaultsIfNeeded()` is called from `DataLayer_Coordinator.init()` on first app launch. It only stamps a `DataLayer_defaultsInitialized` marker — it does **not** enable anything. `isEnabled`, `researchEnabled`, and every consent category default to `false` via the standard `UserDefaults.bool(forKey:)` behavior.

The marker is preserved so future migrations can detect a first launch on a given install. Don't use it as a signal for "user has consented" — it just means the app has booted at least once.

## Event taxonomy

`DataLayer_EventType` defines 28 event types grouped by consent category:

| Category (`DataLayer_ConsentCategory`) | Event types |
|---|---|
| `.glucose` | `.glucoseSample` |
| `.insulin` | `.insulinDelivery` |
| `.carbsAndMeals` | `.carbEntry`, `.mealAnalysis`, `.mealConfirmed`, `.barcodeScanned`, `.mealDebrief`, `.bolusProEntry` |
| `.aiBehavioral` | `.aiSuggestionGenerated`, `.aiSuggestionApplied`, `.aiSuggestionDismissed`, `.aiSuggestionReverted`, `.chatMessage`, `.backgroundAlert` |
| `.biometrics` | `.biometricSnapshot` |
| `.substances` | `.caffeineLogged`, `.alcoholLogged` |
| `.activityAndPresets` | `.presetActivated`, `.presetDeactivated`, `.activityDetected`, `.therapySettingsChanged`, `.overrideActivated`, `.overrideDeactivated`, `.graphDetailViewOpened`, `.siteAtlasPlaced` |
| (lifecycle, no consent gate) | `.sessionStart`, `.sessionEnd` |

Each event type has a corresponding `DataLayer_*Payload` struct in `DataLayer_EventModels.swift`. Payloads are JSON-encoded and stored as `BLOB` in SQLite alongside metadata (timestamp, deviceID, eventType, syncStatus, appVersion).

## Adding a new event type

1. Add a case to `DataLayer_EventType` in `DataLayer_EventModels.swift`.
2. Map it to a consent category via the `consentCategory` switch in the same file.
3. Define a `DataLayer_FooPayload: Codable` struct alongside.
4. In the publishing feature: post a `NotificationCenter` event with a documented `userInfo` shape. Don't import DataLayer types.
5. In `DataLayer_Coordinator`: add an observer in `observeFeatureNotifications()` (or one of its sub-observers) that translates the userInfo dict into the payload struct and calls `collector.record(type:payload:)`.

## Notification names

Feature-side notifications use the `com.loopkit.Loop.<feature><Action>` convention. Current list:

```
com.loopkit.Loop.foodFinderMealAnalyzed
com.loopkit.Loop.foodFinderMealConfirmedForDataLayer
com.loopkit.Loop.foodFinderBarcodeScanned
com.loopkit.Loop.loopInsightsSuggestionEvent
com.loopkit.Loop.loopInsightsCaffeineLogged
com.loopkit.Loop.loopInsightsAlcoholLogged
com.loopkit.Loop.loopInsightsChatMessage
com.loopkit.Loop.loopInsightsMealDebrief
com.loopkit.Loop.therapySettingsChanged
com.loopkit.Loop.overrideActivated
com.loopkit.Loop.overrideDeactivated
com.loopkit.Loop.autoPresetsPresetActivated
com.loopkit.Loop.autoPresetsPresetDeactivated
com.loopkit.Loop.autoPresetsActivityDetected
com.loopkit.Loop.graphDetailViewOpened
com.loopkit.Loop.siteAtlasPlaced
BolusPro_DataLayerHook.notificationName  (carries typed snapshot via userInfo[snapshotUserInfoKey])
```

## Polling-vs-event ingestion

Most features post events as actions occur. Glucose / insulin / carbs are different — Loop's stores update on their own timer driven by pump and CGM callbacks, and there's no convenient hook to post per-sample notifications.

`DataLayer_Coordinator.startPolling()` runs a `Timer` every 5 minutes that:
- Reads new GlucoseStore samples since `lastPollDate` and writes a `glucoseSample` event.
- Reads new DoseStore entries since `lastPollDate` and writes an `insulinDelivery` event.
- Reads new CarbStore entries since `lastPollDate` and writes a `carbEntry` event.
- Every 4 hours, reads HealthKit biometrics (HR, HRV, steps, sleep, energy, weight) and writes a `biometricSnapshot`.

Each query is gated by the relevant consent category. No consent → no read.

## Sync service

`DataLayer_SyncService` runs an upload loop on a background queue. Behavior:

- Polls `EventStore` for events with `syncStatus == .pending`.
- Filters to events whose `consentCategory` is currently granted *and* `researchEnabled == true`.
- Batches up to N events per HTTP POST to `DataLayer_FeatureFlags.ingestEndpointURL`.
- On 2xx: marks events `.uploaded`. On 4xx (non-retryable): marks `.redacted`. On 5xx / network error: increments retry count, exponential backoff (capped at 1 hour).
- The bundled ingest URL is anonymous (no `Authorization` header). If the user pastes a custom URL and provides an API key, the sync service includes `Authorization: Bearer <key>`.

## Provider sharing

`DataLayer_Coordinator.generateShareLink(days:completion:)` builds a one-shot bundle:

1. Reads events from `start = now - days × 86400` through `now`.
2. Filters to events whose `consentCategory` is currently granted.
3. JSON-encodes them into an upload body with `action: "create"`, `days`, `events`, `categories`, `deviceID`.
4. POSTs to `shareEndpointURL`.
5. Server returns `{ url, token }`.
6. A `DataLayer_ShareLink` is appended to `DataLayer_FeatureFlags.activeShares`.

`revokeShareLink(token:completion:)` POSTs `{ action: "revoke", token }` and removes the link from the persisted list. The server is responsible for purging the bundle on its side.

## SQLite schema

```sql
CREATE TABLE events (
    id          TEXT PRIMARY KEY,
    timestamp   REAL NOT NULL,
    device_id   TEXT NOT NULL,
    event_type  TEXT NOT NULL,
    sync_status TEXT NOT NULL,
    app_version TEXT NOT NULL,
    payload     BLOB NOT NULL
);
CREATE INDEX idx_events_type     ON events(event_type);
CREATE INDEX idx_events_status   ON events(sync_status);
CREATE INDEX idx_events_ts       ON events(timestamp);
```

Pruning runs on every `start()` call: deletes rows where `timestamp < now - retentionDays × 86400`.

## Schema versioning

Every payload struct is `Codable` with backward-compatible additions only:
- New fields are added as `Optional` so old payloads decode without error.
- Existing fields are never removed or renamed.
- A `payloadVersion: Int` field is reserved on the wire format for future breaking changes (currently always 1).

## Known limitations / V2 backlog

- **No bulk re-upload of past data.** If the user enables a category mid-stream, only events from that point forward are recorded. Past CGM history isn't backfilled.
- **No purge from research backend on revoke.** Revoking a category stops future uploads, but past uploaded events remain on the backend until a manual purge request.
- **No on-device export.** SQLite file is accessible via Finder → Files → Loop, but there's no in-app "Export to CSV" affordance.
- **Single-endpoint sync.** Sync service uploads to one URL at a time. No fan-out to multiple research backends in v1.
- **Polling interval is fixed.** 5 minutes is hardcoded. A future setting could let users tune this.
