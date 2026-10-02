# FoodFinder

**AI-assisted carb counting at the moment of meal entry.**

## What it does

Tap "Add Carb Entry" in Loop and FoodFinder gives you four ways to fill in the carbs field instead of guessing:

1. **AI Camera** — Take a photo of the meal. The AI returns an itemized breakdown with carbs, fat, protein, fiber, and calories per item.
2. **Barcode Scan** — Scan a packaged food. OpenFoodFacts returns the nutrition panel.
3. **Voice Search** — Speak the meal name ("two slices of pepperoni pizza") and a search returns matching nutrition data.
4. **Text Search** — Type the meal name for the same lookup.

Pick a result, adjust per-item portions if needed, and the carb total auto-populates the Add Carb Entry form. You hit Continue and Loop doses against it normally.

FoodFinder runs on a **bring-your-own API key** model. You configure your preferred AI provider (Claude, OpenAI, or Google Gemini) in Settings and your usage gets billed to your account. PowerPack does not proxy your photos or your data through any backend.

## How to use it

### AI Camera

1. **Open Add Carb Entry** in Loop. The FoodFinder bar appears at the top.
2. **Tap the camera icon.**
3. **Frame the meal** in the camera view. Hold steady; the AI does better with clear, well-lit photos.
4. **Tap the shutter.** The AI runs (typically 3-8 seconds depending on provider).
5. **Review the itemized breakdown.** Each item shows estimated portion, carbs, fat, protein, fiber, calories.
6. **Adjust per-item portions** with the steppers if the AI over- or under-estimated portion size.
7. **Delete items** the AI hallucinated (long-press → Remove) or that you didn't actually eat.
8. **Tap Apply.** Carb total flows into the Add Carb Entry form.

### Barcode Scan

1. **Tap the barcode icon** in the FoodFinder bar.
2. **Point the camera** at the package barcode. It auto-detects.
3. **Review the result** from OpenFoodFacts (carbs, serving size, full panel).
4. **Adjust serving count** if you ate more or less than one serving.
5. **Tap Apply.**

If a product isn't in OpenFoodFacts, the result screen offers a "Try AI Camera" fallback.

### Voice Search

1. **Tap the microphone icon.**
2. **Speak the food** (e.g. "one cup of brown rice").
3. **Pick a match** from the search results.
4. **Adjust portions** with the stepper.
5. **Tap Apply.**

### Text Search

Same as Voice but with the keyboard. Useful when you can't speak (meeting, restaurant) or when voice mishears you.

### Favorite Foods

Any FoodFinder result can be saved as a Favorite from the result screen. Saved favorites display with a thumbnail in your Favorite Foods list, and re-applying a favorite is a single tap with no AI call.

## Familiar foods get smarter

After you've logged the same FoodFinder meal **two or more times**, a **Personal Insight** card appears on the result screen the next time you select it. The card shows your typical post-meal glucose response and suggests a tighter portion or pre-bolus timing based on your own history. This is the **Pre-Meal Advisor** running on your local DataLayer events. It's off by default and lives under Settings → LoopInsights → AI Features.

## Location

If you grant Location access, FoodFinder reverse-geocodes your current GPS coordinates to a place name (e.g. "Chipotle Mexican Grill, Brooklyn"). That place name is included in the AI prompt so the AI can refine its guess based on the restaurant's typical menu. Cuisine context turns out to matter — "burrito at Chipotle" produces a more accurate macro split than "burrito" in isolation.

Location is opt-in. Decline the prompt and FoodFinder works fine without it.

## Configuring it

Settings → FoodFinder Settings:

| Setting | Default | What it does |
|---|---|---|
| **Enable FoodFinder** | OFF | Master toggle. Off → no FoodFinder UI in Add Carb Entry. |
| **AI Provider** | Claude | Choose Claude, OpenAI, Gemini, or BYO. |
| **API Key** | (blank) | Pasted into iOS Keychain. Shared with LoopInsights. |
| **Custom Endpoint URL** *(BYO only)* | (blank) | For self-hosted or alternate AI backends. |
| **Use Location Context** | OFF | Asks for Location permission first time. Sends place name to AI prompt. |
| **Allow Voice Input** | ON | Toggle off to hide the microphone button. |
| **Allow Barcode Scanning** | ON | Toggle off to hide the barcode button. |

## API keys

You provide the key. PowerPack stores it in the iOS Keychain (not UserDefaults, not iCloud). The same Keychain entry is shared with LoopInsights so you only paste once.

To get a key:
- **Claude:** [console.anthropic.com](https://console.anthropic.com) → API Keys
- **OpenAI:** [platform.openai.com](https://platform.openai.com) → API Keys
- **Gemini:** [aistudio.google.com](https://aistudio.google.com) → Get API Key

Typical cost per AI Camera analysis: **$0.005-$0.02** depending on provider and image size. A heavy user logging 60 photos a month pays well under $2/month.

## When the AI gets it wrong

It will. We've shipped multiple bug-driven improvements (the late-April pizza-on-paper-menu OCR confusion is documented in MANIFESTO.md as a real example). General guidance:

- **Adjust the portions before you Apply.** The AI's portion estimate is the largest source of error.
- **Delete hallucinated items.** Sometimes the AI invents a side dish that's actually in the background. Long-press → Remove.
- **Use barcode where possible.** OpenFoodFacts is exact for packaged foods.
- **Save favorites for repeat meals.** A saved favorite has zero AI variance.
- **Watch your glucose response.** If a particular kind of meal is consistently under-estimated, your typical correction pattern feeds back into Pre-Meal Advisor over time.

## Privacy

- **Your photos go to your chosen AI provider, not to PowerPack.** PowerPack has no servers in the AI request path.
- **API keys live in the iOS Keychain** — same as Apple's password manager.
- **Location is opt-in.** Reverse-geocoded place names are sent to the AI prompt only when Location Context is enabled.
- **Barcode lookups go to OpenFoodFacts** — open public database, no account.
- **Favorite Foods are local-only.** Saved favorites never leave the device.
- **DataLayer ingestion is opt-in and gated separately.** FoodFinder broadcasts meal events on `NotificationCenter`, but DataLayer only records them if you've enabled both DataLayer and the Carbs & Meals consent category.

## FAQ

**Q: Can I use FoodFinder offline?**
A: Barcode scan works offline only if the product is already in OpenFoodFacts' offline cache. AI Camera, Voice, and Text all require a network call to your chosen provider.

**Q: Why isn't the carb count auto-applied?**
A: You always tap Apply. By design — FoodFinder is a decision-support tool, not an auto-doser. You see the breakdown, you confirm, then Loop doses against the value you confirmed.

**Q: Can I edit the AI's macro values manually?**
A: Yes. Each row has steppers for portion. The carb total recalculates. Future versions may add per-item macro override.

**Q: Does FoodFinder work without Loop's BolusPro feature?**
A: Yes. They're independent. BolusPro reads FoodFinder's fat and protein when both are enabled, but FoodFinder works fine on its own.

**Q: What happens if my AI provider returns garbage?**
A: The result screen shows the raw AI response and an explanation. You can try a different provider, fall back to manual entry, or report the failure to the project.

---

*FoodFinder is part of Loop (AID) PowerPack. See [FoodFinder_DEVELOPER.md](FoodFinder_DEVELOPER.md) for architecture and developer notes.*
