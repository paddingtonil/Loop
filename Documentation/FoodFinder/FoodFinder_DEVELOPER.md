# FoodFinder — Developer Guide

## Architecture

FoodFinder is a feature-flagged, opt-in module that injects a search/scan/AI bar into Loop's `CarbEntryView`. It produces a `FoodFinder_NutritionResult` value that the host carb entry consumes through a single delegate callback — `onMacrosResolved` — which carries carbs, fat, protein, fiber, calories, and a `macrosSource` tag.

Every AI request goes directly from the user's device to the user's chosen provider with the user's API key. PowerPack does not proxy. There are no FoodFinder servers.

## File map

```
Loop/
├── Models/FoodFinder/
│   ├── FoodFinder_Models.swift                 // NutritionResult, ResultItem, MacrosSource
│   ├── FoodFinder_AnalysisRecord.swift         // Persisted history entry for repeat-meal detection
│   └── FoodFinder_InputResults.swift           // Per-input-type result envelope
├── Resources/FoodFinder/
│   └── FoodFinder_FeatureFlags.swift           // Master toggle + UserDefaults keys
├── Services/FoodFinder/
│   ├── FoodFinder_AIAnalysis.swift             // Builds prompts, parses responses
│   ├── FoodFinder_AIServiceAdapter.swift       // Provider-agnostic HTTP client
│   ├── FoodFinder_AIServiceManager.swift       // Provider switching, retries, error mapping
│   ├── FoodFinder_AIProviderConfig.swift       // Per-provider config (model, max tokens, etc.)
│   ├── FoodFinder_OpenFoodFactsService.swift   // Barcode lookup against off.org
│   ├── FoodFinder_ScannerService.swift         // Vision barcode detection
│   ├── FoodFinder_VoiceService.swift           // Speech recognition wrapper
│   ├── FoodFinder_LocationService.swift        // CLLocationManager + reverse geocode
│   ├── FoodFinder_SearchRouter.swift           // Routes input type → service
│   ├── FoodFinder_CarbTrackingService.swift    // Repeat-meal detection
│   ├── FoodFinder_AnalysisHistoryStore.swift   // 90-day local history
│   ├── FoodFinder_ImageDownloader.swift        // Async image fetch + cache
│   ├── FoodFinder_ImageStore.swift             // Local thumbnail cache for favorites
│   ├── FoodFinder_EmojiProvider.swift          // Heuristic emoji per food category
│   └── FoodFinder_SecureStorage.swift          // Keychain wrapper for API keys
├── View Models/FoodFinder/
│   └── FoodFinder_SearchViewModel.swift        // All search/scan/AI state
└── Views/FoodFinder/
    ├── FoodFinder_EntryPoint.swift             // Embedded UI inside CarbEntryView
    ├── FoodFinder_SearchBar.swift              // Multi-mode search input
    ├── FoodFinder_SearchResultsView.swift      // Result list + per-item portion control
    ├── FoodFinder_AICameraView.swift           // Camera + AI capture flow
    ├── FoodFinder_ImageCropView.swift          // Pre-AI crop UI
    ├── FoodFinder_ScannerView.swift            // Barcode camera view
    ├── FoodFinder_VoiceSearchView.swift        // Voice input view
    ├── FoodFinder_FavoritesHelpers.swift       // Favorite save/load helpers
    ├── FoodFinder_CarbTrackingDashboard.swift  // History + Personal Insight surface
    └── FoodFinder_SettingsView.swift           // Provider config screen

LoopTests/FoodFinder/
├── FoodFinder_OpenFoodFactsTests.swift
├── FoodFinder_BarcodeScannerTests.swift
└── FoodFinder_VoiceSearchTests.swift

Documentation/FoodFinder/
├── FoodFinder_README.md                        // User guide
└── FoodFinder_DEVELOPER.md                     // This file
```

## Existing Loop files modified

| File | Diff size | Why |
|---|---|---|
| `Loop/Views/CarbEntryView.swift` | ~9 lines | Embeds `FoodFinder_EntryPoint`, wires `onMacrosResolved` callback |
| `Loop/Views/SettingsView.swift` | ~16 lines | Adds FoodFinder Settings navigation link |
| `Loop/Views/FavoriteFoodDetailView.swift` | ~4 lines | Renders thumbnail when a favorite has one |

Total: ~29 lines across 3 existing Loop files. No LoopKit changes.

## Data flow at meal entry

```
User opens CarbEntryView
  └─→ FoodFinder_EntryPoint renders below the standard fields

User picks an input mode (camera, barcode, voice, text, favorite)
  └─→ FoodFinder_SearchViewModel routes to the matching service

Service returns FoodFinder_NutritionResult
  ├── carbs, fat, protein, fiber, calories
  ├── macrosSource: .ai | .product | .favorite | .manual
  ├── itemized breakdown (multiple items for AI Camera; single for barcode)
  └── absorption time hint (carb-only meal vs. high-FPU meal)

User adjusts per-item portions and taps Apply
  └─→ onMacrosResolved callback fires
       ├── CarbEntryViewModel.applyFoodFinderMacros(...) updates carbs field
       ├── BolusPro reads fat/protein from the same callback (if enabled)
       └── FoodFinder posts NotificationCenter event for DataLayer ingest

Carb entry continues through Loop's normal save path
  └─→ FoodFinder posts mealConfirmed notification with the final value
```

## AI provider abstraction

`FoodFinder_AIServiceAdapter` exposes a single async `analyze(image:context:) -> AIAnalysisResponse` method. Behind it, four concrete providers are configured by `FoodFinder_AIProviderConfig`:

| Provider | Endpoint | Model default |
|---|---|---|
| Claude | `https://api.anthropic.com/v1/messages` | `claude-sonnet-4-5` |
| OpenAI | `https://api.openai.com/v1/chat/completions` | `gpt-4o` |
| Gemini | `https://generativelanguage.googleapis.com/v1beta/models/...` | `gemini-2.0-flash` |
| BYO | user-provided URL | user-provided model |

`FoodFinder_AIServiceManager` handles:
- Provider selection from `FoodFinder_FeatureFlags.aiProvider`
- API key resolution from `FoodFinder_SecureStorage` (shared keychain entry with LoopInsights)
- Retry on transient errors (rate limit, timeout) with backoff
- Error normalization to `FoodFinder_AIError` for consistent UI handling

## Prompt construction

`FoodFinder_AIAnalysis.buildPrompt(...)` produces a structured prompt requesting JSON output with this shape:

```json
{
  "items": [
    { "name": "Pepperoni Pizza Slice",
      "portion": "1 slice (~125g)",
      "carbs": 33, "fat": 14, "protein": 12, "fiber": 2, "calories": 285 }
  ],
  "totals": { "carbs": 33, "fat": 14, "protein": 12, "fiber": 2, "calories": 285 },
  "confidence": 0.78,
  "absorption_hint": "high_fpu"
}
```

When `LocationService` returns a place name, the prompt includes a `location_context` field. The AI is instructed to refine portion size and item names based on the venue's typical menu.

A fast OCR gate runs `VNDetectTextRectanglesRequest` against the captured frame before the AI call. If text density is high (paper menu, ingredients label), the AI receives a hint to focus on actual food in the frame, not menu text. This was added after the late-April pizza-on-paper-menu OCR confusion (see MANIFESTO).

## Repeat-meal detection (Pre-Meal Advisor wiring)

`FoodFinder_AnalysisHistoryStore` persists every AI/barcode result with a 90-day retention. `FoodFinder_CarbTrackingService` matches new results against history by name + venue + macro fingerprint. When the same meal has been logged ≥2 times, the result screen surfaces a "Personal Insight" card driven by `LoopInsights_PreMealAdvisorService` (DataLayer-backed). FoodFinder doesn't compute the insight — it just provides the match signal and lets PreMealAdvisor render.

## Favorites

`FavoriteFoodStore` (Loop's existing model) is reused. FoodFinder adds:
- `FoodFinder_ImageDownloader` to fetch product / venue images
- `FoodFinder_ImageStore` to cache them locally as thumbnails
- `FavoriteFoodDetailView` modification to render the thumbnail
- One-tap re-apply of a favorite skips the AI/network round trip entirely

## DataLayer events

Posted via `NotificationCenter` to keep FoodFinder decoupled from DataLayer:

| Notification | Payload | DataLayer event |
|---|---|---|
| `com.loopkit.Loop.foodFinderMealAnalyzed` | analysisType, foodName, carbsGrams, originalAICarbs, aiConfidencePercent, protein/fat/fiber/calories, absorptionTimeHours, locationName, itemCount | `.mealAnalysis` |
| `com.loopkit.Loop.foodFinderMealConfirmedForDataLayer` | mealEventID, finalCarbsGrams, carbDeltaFromAI | `.mealConfirmed` |
| `com.loopkit.Loop.foodFinderBarcodeScanned` | barcode, productName, carbsGrams, source, found | `.barcodeScanned` |

Both `mealAnalysis` and `mealConfirmed` are gated under the Carbs & Meals consent category. `originalAICarbs` and `carbDeltaFromAI` are the raw signal Pre-Meal Advisor learns from.

## Permissions

| Permission | Required for | Prompt timing |
|---|---|---|
| Camera | AI Camera, Barcode Scan | First time user taps camera or barcode icon |
| Microphone | Voice Search | First time user taps the microphone icon |
| Speech Recognition | Voice Search | First time user taps the microphone icon |
| Location (When In Use) | Location Context (opt-in) | First time user enables Location Context |

All permissions are checked before each use and surface a settings-redirect alert if denied.

## Known limitations / V2 backlog

- **No multi-image analysis.** AI Camera analyzes one frame at a time. A 360° pan or multiple plate angles aren't supported in v1.
- **No per-item macro override.** User can adjust portion (multiplier) but not edit raw macro values per item.
- **Barcode lookup is OpenFoodFacts only.** No fallback to USDA FoodData Central or commercial APIs.
- **No offline AI.** All AI analysis requires a live network call to the chosen provider.
- **Voice transcription is iOS-default.** Doesn't yet route through the user's preferred AI provider for higher-accuracy food-domain transcription.
