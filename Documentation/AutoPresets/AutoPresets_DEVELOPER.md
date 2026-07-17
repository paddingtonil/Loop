# AutoPresets — Developer Guide

## Architecture

AutoPresets is a feature-flagged, opt-in module that activates a Loop override preset when sustained walking or running is detected via CoreMotion, and deactivates it when motion stops. It deliberately avoids LoopKit changes — preset activation flows through Loop's existing override schedule and `TemporaryScheduleOverride` API.

The detection pipeline runs entirely on the device using `CMPedometer` (step counts) and `CMMotionActivityManager` (activity classifier). No HealthKit dependency, no network egress.

## File map

```
Loop/
├── Models/AutoPresets/
│   ├── AutoPresets_Models.swift                  // Settings, log entries, enums
│   └── AutoPresets_RecommendationModels.swift    // AI recommendation models (advanced)
├── Resources/AutoPresets/
│   └── AutoPresets_FeatureFlags.swift            // Master toggle + storage keys
├── Services/AutoPresets/
│   └── AutoPresets_AIAdvisor.swift               // Optional AI suggestions for preset config
├── Managers/AutoPresets/
│   ├── AutoPresets_Coordinator.swift             // Main entry, lifecycle, public API
│   ├── AutoPresets_ActivityDetectionManager.swift // CoreMotion pedometer + classifier
│   ├── AutoPresets_CalendarManager.swift         // EventKit calendar trigger support
│   ├── AutoPresets_GeofenceManager.swift         // CoreLocation geofence trigger support
│   ├── AutoPresets_Delegate.swift                // Bridge to LoopDataManager override API
│   ├── AutoPresets_Logger.swift                  // File-based debug log
│   └── AutoPresets_Storage.swift                 // UserDefaults persistence + legacy migration
└── Views/AutoPresets/
    ├── AutoPresets_SettingsView.swift            // Main settings UI
    ├── AutoPresets_AIRecommendationView.swift    // AI suggestion review screen
    ├── AutoPresets_CalendarSettingsView.swift    // Calendar trigger config
    └── AutoPresets_GeofenceSettingsView.swift    // Geofence trigger config

Documentation/AutoPresets/
├── AutoPresets_README.md                         // User guide
└── AutoPresets_DEVELOPER.md                      // This file
```

## Existing Loop files modified

| File | Diff size | Why |
|---|---|---|
| `Loop/Managers/LoopDataManager.swift` | +18 lines | Initializes `AutoPresets_Coordinator.shared`, wires the delegate to `LoopDataManager`'s override API |
| `Loop/Views/SettingsView.swift` | +6 lines | Adds `autoPresetsSettingsRow` NavigationLink (feature-flag-gated) |

Total: ~24 lines across 2 existing Loop files.

## Detection pipeline

```
CMPedometer.startUpdates(...)
    │
    ├── pedometer callback fires (steps accumulated)
    │   └── if stepDelta ≥ 20  → start confirmation timer (default 30s)
    │
    ├── confirmation timer fires
    │   ├── stepRate = totalSteps / actualElapsedSeconds
    │   ├── recencyOK = lastStepTimestamp within scaled window
    │   ├── classifierType ∈ {walking, running} via CMMotionActivity
    │   ├── all 3 pass? → activate assigned preset → enter "active" state
    │   └── any fail? → reset to idle
    │
    └── while active:
        ├── stop timer runs (default 5min) — restarted on every step delta
        ├── stop timer fires with no recent steps → deactivate preset
        └── return to idle
```

## iOS background timing compensation

iOS aggressively suspends Loop. A 60-second `Timer` can fire at 200+ seconds. AutoPresets adapts:

- **Step rate** is computed against actual elapsed time (`Date().timeIntervalSince(startedAt)`), not the configured interval. A 30-second confirmation that fires at 200 seconds with 100 steps produces `100 / 200 = 30 steps/min`, not `100 / 30 = 200 steps/min`.
- **Recency window** scales with the actual elapsed time. A walk that took 200 seconds to reach the confirmation point still passes the recency check if steps were recorded within the last `actualElapsed / 4` seconds.
- **Stop timer** only restarts when `pedometerData.numberOfSteps` actually changes, not on every callback. Without this, idle pedometer "ping" callbacks would prevent deactivation.

## High-confidence classifier toggle (hidden)

`AutoPresets_FeatureFlags.requireHighConfidence` exists but is intentionally hidden from the UI. CoreMotion's `CMMotionActivity` classifier is too slow and too unreliable to gate confirmation — it often reports `unknown` for the entire walk, or only reaches `medium` confidence after the user has already stopped. Step rate + recency are sufficient. The flag remains in code for potential future use (e.g. when CoreMotion improves, or for a debug build).

## Override semantics

AutoPresets does not modify LoopKit's override engine. It calls Loop's existing `LoopDataManager.scheduleOverride(_:)` to activate, and `LoopDataManager.clearOverride(_:)` to deactivate. The override is created from the user-assigned preset name (`TemporaryScheduleOverridePreset`) so it inherits the user's existing target range, insulin needs scale, and duration semantics.

Two safety constraints:

1. **Won't activate over an existing override from another source.** `AutoPresets_Coordinator.shouldActivate` checks `loopManager.settings.scheduleOverride == nil`. Manual overrides take precedence.
2. **Won't deactivate an override it didn't create.** Each AutoPresets-driven override is tagged in `AutoPresets_Storage.activeAutoOverride`. Deactivation only fires if the currently-active override matches the tag.

## Calendar + Geofence triggers (advanced)

Beyond motion detection, AutoPresets supports two opt-in trigger sources:

- **`AutoPresets_CalendarManager`** observes EventKit. When a calendar event whose title matches a configured pattern (e.g. "Gym") starts, the assigned preset activates. When it ends, the preset deactivates.
- **`AutoPresets_GeofenceManager`** registers `CLCircularRegion` boundaries. Entry activates a preset; exit deactivates.

Both are opt-in per trigger and require the relevant iOS permission (Calendar, Always-On Location). They piggy-back on the same `AutoPresets_Delegate` that the motion pipeline uses, so override semantics are identical regardless of trigger source.

## DataLayer events

Posted via NotificationCenter to keep AutoPresets decoupled from DataLayer:

| Notification | Payload (userInfo) | DataLayer event |
|---|---|---|
| `com.loopkit.Loop.autoPresetsActivityDetected` | `activityType: String` | `.activityDetected` |
| `com.loopkit.Loop.autoPresetsPresetActivated` | `activityType: String, presetName: String` | `.presetActivated` |
| `com.loopkit.Loop.autoPresetsPresetDeactivated` | `activityType: String, presetName: String` | `.presetDeactivated` |

DataLayer's coordinator translates these into typed `DataLayer_PresetEventPayload` events under the `.activityAndPresets` consent category.

## AI recommendations (optional)

`AutoPresets_AIAdvisor` analyzes recent override outcomes (glucose response during the override window vs. the user's normal-target baseline) and proposes adjustments to insulin needs scale or target range. The recommendation is presented as a review card in `AutoPresets_AIRecommendationView` — never auto-applied. Uses the shared LoopInsights API key + provider configuration (FoodFinder shares the same keychain entry).

## Permissions

- **Motion & Fitness** — Required. Without it, `CMPedometer.startUpdates` returns no data.
- **Calendar** — Required only if Calendar triggers are enabled.
- **Location (Always)** — Required only if Geofence triggers are enabled.

`AutoPresets_Coordinator.checkPermissions()` returns the current status without prompting; the actual prompts fire from the corresponding settings screens when the user enables that trigger source.

## Debug logging

`AutoPresets_Logger` writes timestamped events to `Documents/AutoPresets/debug.log`. Captured events:

- Every pedometer update with step delta
- Threshold crossings and confirmation timer creation
- Confirmation result with rate / recency / classifier values
- Override activation / deactivation
- Permission errors
- Calendar / geofence trigger events

Log auto-truncates at 5 days or 100 KB. Available via Settings → AutoPresets → Debug Log.

## Known limitations / V2 backlog

- **Single preset per activity.** Walking always maps to one preset. Can't say "Walking on weekdays = preset A, Walking on weekends = preset B" without manual swapping.
- **No outcome learning.** AI recommendations are one-shot, not continuous. V2 could learn the right insulin needs scale per activity from observed glucose response.
- **No watch integration.** All detection runs on the iPhone. Apple Watch could provide a more reliable activity signal, but plumbing it through the iPhone-side coordinator hasn't been built.
