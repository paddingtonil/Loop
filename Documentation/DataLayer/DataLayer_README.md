# DataLayer

**Privacy-first event store for your dosing data, with opt-in cloud upload.**

## What it does

DataLayer is the analytics backbone behind several PowerPack features (Behavior Insights, Meal Debrief, Caregiver Digest, the personal analytics dashboard). It records discrete events as they happen — a meal logged, a bolus delivered, an override activated, a CGM sample arriving — into a local SQLite store on your device. With your consent, those events can also be uploaded to a research backend or a time-scoped share link for your endocrinologist.

**Default state: completely off.** Master toggle is OFF. Every consent category is OFF. Nothing is collected and nothing is uploaded until you explicitly opt in.

## How to use it

1. **Enable LoopInsights first.** DataLayer lives under LoopInsights' settings.
2. **Open Settings → LoopInsights → Data Sharing.**
3. **Turn on "Enable Data Sharing"** (the master toggle).
4. **Toggle the categories you want to record.** Each is independent.
5. **Optionally turn on "Contribute to Research"** if you want your enabled categories uploaded to the project research backend.
6. **Optionally generate a Share Link** for a clinician — see the Provider Sharing section below.

The categories you enable record events locally from that point forward. Earlier history isn't backfilled.

## The 7 consent categories

Each is independent. Enabling one has no effect on the others.

| Category | What it records |
|---|---|
| **Glucose** | CGM glucose readings and trend arrows |
| **Insulin** | Basal and bolus deliveries (manual + automatic) |
| **Carbs & Meals** | Carb entries, FoodFinder analyses, barcode scans, meal debriefs |
| **AI & Behavioral** | LoopInsights suggestion lifecycle, chat topics, alert events, settings changes |
| **Biometrics** | Heart rate, HRV, steps, sleep, active energy, weight (every 4 hours) |
| **Substances** | Caffeine and alcohol log entries |
| **Activity & Presets** | AutoPresets activity detection, override activations, GraphDetailView opens |

## How uploads work

DataLayer ships with a **bundled ingest endpoint** baked into the AllFeatures build. When you enable "Contribute to Research," consented events are uploaded to that endpoint. The endpoint is anonymous (no API key required from you).

If you'd rather upload to your own backend, paste your URL into the **Custom Ingest Endpoint** field in Data Sharing. To stay local-only, leave research disabled and don't generate share links. Local-only DataLayer still powers Behavior Insights and Meal Debrief — those run entirely on-device.

## Provider sharing

Settings → LoopInsights → Data Sharing → Generate Share Link.

1. Choose how many days of data to include (7 / 14 / 30 / 90).
2. DataLayer bundles your consented events for that range and posts them to the share endpoint.
3. The endpoint returns a time-scoped URL with an opaque token.
4. Send the URL to your endocrinologist or care team.
5. They view the data in a browser — no app install needed.
6. The link auto-expires after the same number of days you selected.
7. You can revoke a link at any time from the Active Shares list.

Only the categories you've consented to are included in the share. A category turned off mid-share-period simply isn't represented.

## Retention

- Events are retained locally for **90 days** by default.
- After 90 days, events are auto-pruned on next launch.
- You can change retention in Data Sharing → Retention Period.
- "Delete All My Data" wipes the local SQLite store, revokes all consent, clears the keychain, and disables the feature.

## Privacy guarantees

- **Local-first.** Every event is written to the local SQLite store *before* any upload is considered.
- **Per-category consent.** No category is consented to by default. Each toggle is explicit and independently revocable.
- **No PII in payloads.** Events carry an anonymized device ID (a random UUID generated once on the device, stored in the keychain). Your name, email, Apple ID, and Loop account ID are never included.
- **No third-party brokers.** The bundled endpoint is hosted on Google Cloud Run by the PowerPack project. You can point at your own URL or no URL at all.
- **Audit trail.** Every consent change (granted or revoked) is logged with a timestamp. The last 500 changes are queryable via the Data Sharing screen.
- **Revocation is destructive.** Revoking a category does not retroactively delete past uploads from the research backend. Future uploads stop immediately. To purge past data, contact the project maintainers.

## FAQ

**Q: Why ship a default ingest endpoint at all?**
A: So opt-in works zero-config. Most users who want to contribute to research don't want to also operate cloud infrastructure. The endpoint is anonymous and rate-limited. Replace it with your own URL if you'd rather.

**Q: What happens if I'm offline when an upload would fire?**
A: Events queue locally. The sync service retries with exponential backoff when the device is back online.

**Q: Does turning off DataLayer disable Behavior Insights?**
A: Yes. Behavior Insights, Meal Debrief, and Pre-Meal Advisor all read from the local DataLayer event store. Disable DataLayer and they have no data to work with.

**Q: Can I export my own data?**
A: V1 doesn't have a one-click export. The local SQLite file lives in the app's Documents directory and can be retrieved via Finder → Files → Loop. Direct export is on the V2 backlog.

---

*DataLayer is part of Loop (AID) PowerPack. See [DataLayer_DEVELOPER.md](DataLayer_DEVELOPER.md) for architecture and developer notes.*
