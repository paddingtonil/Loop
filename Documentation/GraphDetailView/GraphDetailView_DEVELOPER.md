# GraphDetailView — Developer Guide

## Architecture

GraphDetailView is a SwiftUI popup overlay rendered on top of the home-screen status chart. It is driven by a UIKit long-press + pan gesture installed on the chart container, and backed by a view model that reads from the same data stores the chart already uses (`GlucoseStore`, `DoseStore`, `CarbStore`, `LoopOverrideHistory`, `HealthKit`).

It deliberately has **no master feature flag**. It is the lone always-on PowerPack feature — see the README for the rationale.

The feature broadcasts a single `NotificationCenter` event on every popup appearance (`com.loopkit.Loop.graphDetailViewOpened`). DataLayer's coordinator listens for this and records a `graphDetailViewOpened` event when the user has enabled DataLayer + the Activity & Presets consent category. Without DataLayer enabled, the broadcast goes nowhere — the feature has zero compile-time DataLayer dependency.

## File map

```
Loop/
├── Views/
│   └── GraphDetailView.swift              // SwiftUI popup, header + data rows
└── Managers/
    └── GraphDetailViewModel.swift         // ObservableObject, store reads, scrub throttle

Documentation/GraphDetailView/
├── GraphDetailView_README.md              // User guide
└── GraphDetailView_DEVELOPER.md           // This file
```

Total: 2 new files in the Loop submodule.

## Existing Loop files modified

| File | Diff size | Why |
|---|---|---|
| `Loop/View Controllers/StatusTableViewController.swift` | ~120 lines | Installs the long-press + pan gesture, hosts the SwiftUI popup in a `UIHostingController`, manages position constraints, scrub haptics, auto-fade timer, dismiss tap |

The StatusTableViewController hooks live in a single `MARK: - GraphDetailView (Long-Hold Detail Popup)` section near the bottom of the file, plus 7 stored properties at the top of the class. The gesture installation disables the original chart touch-highlight so the two don't fight.

## Data flow

```
User long-presses chart
  └─→ StatusTableViewController gesture handler
       ├── Map touch X → date via chart's xRange / contentSize
       ├── Build GraphDetailViewModel(date:, glucoseUnit:, deviceManager:)
       ├── Render GraphDetailView in UIHostingController
       └── Position via constraints near the touch point

User drags
  └─→ Each touch update calls graphDetailViewModel.update(for: date)
       ├── data.date = date  (immediate display update)
       ├── If outside throttle window → reloadAtCurrentDate() now (leading edge)
       └── If inside window → schedule trailing reload at window end

User lifts finger
  └─→ Auto-fade timer scheduled (5s)
       └─→ removes hosting controller from view hierarchy
```

## Scrub throttle

`GraphDetailViewModel.update(for:)` uses a **leading-edge throttle** with a 150ms window:

- The first call (or any call after a quiet period ≥ 150ms) reloads immediately so the popup updates live as the user drags.
- Subsequent calls inside the window are coalesced into a single trailing reload that fires once the window closes.
- Net effect: ~6 updates/sec during continuous drag, with a guaranteed final reload at the user's stop position.

This replaces the previous pure-debounce behavior, which suppressed every reload until the user lifted their finger and made the popup feel laggy mid-scrub.

## Data sources

`GraphDetailViewModel.reloadAtCurrentDate()` clears the existing `GraphDetailData` (so stale fields from the previous date don't linger) and then issues parallel reads:

| Series | Source | Match strategy |
|---|---|---|
| Glucose | `deviceManager.glucoseStore.getGlucoseSamples(start:end:)` over a ±5min window | nearest sample to `data.date` |
| IOB | `deviceManager.loopManager.getLoopState` insulin counterations | active value at `data.date` |
| COB | `deviceManager.loopManager.getLoopState` carbs on board | active value at `data.date` |
| Bolus | `deviceManager.doseStore.getNormalizedDoseEntries` over the prior hour | most recent `.bolus` before `data.date` |
| Basal | DoseStore `.tempBasal` and `.basal` covering the timestamp | rate active at `data.date` |
| Preset | `deviceManager.loopManager.settings.scheduleOverride` history | active override at `data.date` |
| AutoPreset | `AutoPresets_Coordinator.shared.activityForOverride(name:)` lookup keyed by override name | currently-active AutoPresets activity |
| Heart Rate | HealthKit `HKQuantityType(.heartRate)` over a ±2min window | nearest sample to `data.date` |

Empty fields stay nil and the corresponding row is hidden in the UI.

## DataLayer event

`GraphDetailView.postOpenedNotification()` posts on `.onAppear`:

```swift
NotificationCenter.default.post(
    name: Notification.Name("com.loopkit.Loop.graphDetailViewOpened"),
    object: nil,
    userInfo: [
        "hasGlucose":    data.glucoseValue   != nil,
        "hasIOB":        data.insulinOnBoard != nil,
        "hasCOB":        data.carbsOnBoard   != nil,
        "hasBolus":      data.recentBolus    != nil,
        "hasBasalRate":  data.basalRate      != nil,
        "hasPreset":     data.activePreset   != nil,
        "hasAutoPreset": data.activeAutoPreset != nil,
        "hasHeartRate":  data.heartRate      != nil
    ]
)
```

Only the *presence* of each series is recorded — never the values. `DataLayer_Coordinator.observeGraphDetailViewNotifications()` translates this into a `DataLayer_GraphDetailViewOpenedPayload` event.

## Known limitations / V2 backlog

- **Touch precision in landscape.** The popup positioning uses the touch X relative to the chart container. In landscape with a wider chart, the popup can clip off-screen near the right edge. The constraint logic clamps to the safe area, but the popup occasionally jumps when the constraint flips from leading to trailing. Acceptable for now.
- **No keyboard / accessibility scrub.** Cursor scrub is finger-only. A VoiceOver user can read the underlying chart value but can't summon the detail popup at an arbitrary moment.
- **Heart rate single-source.** Only reads the active HealthKit heart rate type. Doesn't fall back to Apple Watch workout heart rate samples or third-party sources.
