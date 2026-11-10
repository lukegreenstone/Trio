# Rheos safety boundary

Rheos is a learning layer in this fork. Trio remains the insulin app. Medtrum and Libre stay on Trio's existing device managers. Rheos never opens a pump or CGM session.

The hourly fit reads Trio's saved BG target schedule (the middle of each low/high slot) and does not write it. There is no fixed 110 mg/dL anchor in that path. The per-day factor step defaults to 0.05 and cannot be saved above 0.10. The same-day context nudge defaults to 0.10 and cannot be saved above 0.20.

The chat prefers Apple's on-device Foundation Models framework on iOS 26 when Apple Intelligence is available. Otherwise it can call an OpenAI-compatible endpoint with a key the user types into Rheos settings. That key is stored in the Keychain and is not in the repository. If neither is available, the reply is the local report summary. Parsed `[[suggestion]]` blocks become notes only after a tap. The chat cannot dose or change limits.

## What can change insulin

Only while the in-app mode is **Scharf**, and only after the hourly model has enough data and passes walk-forward.

The single call site is `OpenAPS.createProfiles` in `Trio/Sources/APS/OpenAPS/OpenAPS.swift`. It asks `RheosProfileHook.applying` for copies of the basal schedule, ISF schedule and carb-ratio schedule, then passes those copies into the existing `ProfileGenerator`. The user's settings files (`basal_profile.json`, `insulin_sensitivities.json`, `carb_ratios.json`, `preferences.json`, `settings.json`) are not written.

`ProfileGenerator` still copies SMB flags, UAM, max SMB minutes, max IOB and autosens min/max from the **unchanged** preferences. Determine-basal, the dosing engine, temp basal and SMB/UAM are not edited. They see the scaled profile the same way they see any other profile, so late-night SMB/UAM corrections keep working. Rheos does not issue a bolus and has no pump command.

Aus (the default) and Schatten return the original schedules, so the generated profile matches Trio without Rheos.

## Bounds

- Default multipliers: **0.7–1.2**, the same numbers as Trio's default autosens min/max.
- The settings screen can change the band.
- At apply time the band is the intersection with the autosens min/max Trio is already using for that loop. Rheos cannot widen them.
- A change moves at most the configured daily step (default 0.05) once per calendar day, starting from 1.0.
- A scaled basal rate is not raised above the user's max basal. An ISF that was at least 5 mg/dL per unit is not taken below 5, and a carb ratio that was inside 1–150 stays inside that range, because Trio rejects profiles outside those bounds.
- When a scale is actually applied, the runtime profile passed to the algorithm is expanded to 24 hourly entries so each hour uses its own factor. The files the user edits in the profile editors are not rewritten. Aus and Schatten keep the original schedule shape.
- If data are thin, walk-forward fails, or autosens is pinned at 1 (basal testing), the factors stay 1 and the reason is stored.

## What still needs a tap

Context modes (Showtime, Urlaub, Krank, Fasten, Sport), a snack note, a meal name such as Standardfrühstück, and Alkohol are optional announcements. Confirming one on the phone or the watch calls `RheosCoordinator.announce`, which stores a note. It does not activate a Trio preset, does not call `AdjustmentManager`, and does not deliver insulin. Scharf still changes only ISF, carb ratio and basal from the learned profile, without that announcement.

Meal outcomes can be marked as seen. That writes a flag in the Rheos log only.

The chat stub answers from the on-device report. It has no network client. Body data never becomes an insulin number.

## Suggestions that do not dose

Trio already has high and low glucose alarms, a forecasted-low alarm, and an oref “carbs required” alarm. The Statistics screen already shows TITR (70–140), TIR against the user’s limits, and CV. Pump history already has a site-change event, and a rewind can reset autosens. Rheos does not replace any of those.

Rheos adds only notes and local notifications whose identifiers start with `rheos.suggestion.`:

- high glucose that is not falling despite insulin → check ketones and the Medtrum patch
- a night-time drop that bounces back is left out of learning; that detection does not mute Trio's low alarms
- a body-site log compares glucose after each patch change the user records
- a 7-day text report for the diabetes team
- a 30-minute hypo extrapolation whose carb grams come only from past treatments that were followed by a recovery
- an optional alcohol note that can mention a temp target the user would set in Trio

None of these write insulin, carbs, targets, or limits.

## Watch and alarm silence

Trio already had a watch app (glucose, carbs, bolus confirmation, overrides, temp targets) and a snooze (`TrioAlertManager.applySnooze`, 15 min / 1 h / 3 h / 6 h) that the watch notification actions already forwarded with `WatchMessageKeys.snoozeDuration`. Those screens and the bolus request are unchanged. Rheos is a new page on the same watch app. It uses the same `WCSession`: `sendMessage` when the phone is reachable, `transferUserInfo` when the phone is nearby but the watch session is not currently reachable. That is the path that works with the phone on a tripod.

The phone sheet and the watch page can silence alarms for 1, 2, 4 or 6 hours, or a custom duration up to 12 hours. Vibrate only keeps the banner and triggers a vibration without a tone. Fully silent hides ordinary alarms. An urgent-low alarm, and any glucose reading under 55 mg/dL, still sounds and vibrates. Critical pump alerts such as an occlusion still sound. The sheet and the watch page say this. Ending the snooze clears the style. A notification action that only sends minutes keeps the older full mute of non-urgent alarms, and the urgent-low floor still applies.

Watch buttons for Showtime, Sport, Snack ("small carbs, observe"), Standardfrühstück and Alkohol send a confirm message. Suggestion rows send confirm or reject. A short text field uses the watch keyboard, including its dictation button, and the phone answers with the same chat engine as the phone screen. None of those messages include a bolus amount. If a payload also contains a bolus or carb key, Rheos ignores it and the existing treatment handler keeps it. A bolus is still only the existing watch bolus flow and its confirmation.

## Watch face

Trio already shipped a WidgetKit complication (`Trio Watch Complication`, kind `TrioWatchComplication`). It drew the app icon and used a timeline policy of `.never`, so the watch face did not show glucose. That same extension now offers circular, corner, rectangular, and inline families. The rectangular family is the one watchOS puts in the Smart Stack.

The face shows glucose, the trend arrow, how old the reading is, and the Rheos mode (Aus, Schatten, Scharf). The watch app writes that snapshot into the existing Trio app group (`$(APP_GROUP_ID)`). The Browser Build instructions already attach that group to the watch app and the complication identifiers. No new group identifier is added. The complication only reads the snapshot.

WidgetKit has a small daily reload budget and can defer reloads. The watch app calls `reloadTimelines` at most every 5 minutes, and only when glucose, trend, or Rheos mode changed. Each timeline contains one entry per minute for 15 minutes, so the age label moves without another reload. A reading 15 minutes or older is shown as stale. With the phone nearby, the face is typically within about 5 minutes of the latest value stored on the watch. It is not a live every-minute trace, and it does not replace Trio's glucose alarms.

## Storage

Rheos files live under Application Support `/Rheos` in this app's container. The bundle ID does not change, so an update or a later build of this fork keeps the same directory. The canonical file is `rheos-state.json`. It has a schema version. Older files are copied to `rheos-state.vN.bak` and then rewritten forward. A file from a newer build is not rewritten back down, and a file that cannot be parsed is left in place. Nothing in that directory is marked excluded from the device backup. On iPhone the file is written with complete-until-first-unlock protection.

iCloud Drive is optional. This change does not add an entitlement, so the Browser Build keeps using the current HealthKit profile. `url(forUbiquityContainerIdentifier:)` returns nil until iCloud Documents is on the App ID, and Rheos then only keeps the local file. To turn the copy on later:

1. Open [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/identifiers/list) and select the Trio identifier (`org.nightscout.TEAMID.trio`, with your team id).
2. Enable **iCloud**, choose **Include CloudKit support** only if you want CloudKit later. For this build, **iCloud Documents** is enough. Add a container, or accept the default `iCloud.` plus the bundle ID. Save.
3. The provisioning profile has to be created again so it contains the entitlement. With Browser Build, run **4. Build Trio** once after the identifier change. Match recreates the profile from the App ID. If the build still has the old profile, the Match-Secrets repo may need the stale `profiles/development` and `profiles/appstore` entries for this app removed so the next build fetches a new one. Do not edit the workflow files for this.
4. Add the keys to `Trio/Resources/Trio.entitlements` only after that profile exists, then build again:

```xml
<key>com.apple.developer.icloud-services</key>
<array>
    <string>CloudDocuments</string>
</array>
<key>com.apple.developer.icloud-container-identifiers</key>
<array>
    <string>iCloud.$(PRODUCT_BUNDLE_IDENTIFIER)</string>
</array>
<key>com.apple.developer.ubiquity-container-identifiers</key>
<array>
    <string>iCloud.$(PRODUCT_BUNDLE_IDENTIFIER)</string>
</array>
```

Until those keys are present, signing does not ask for iCloud and the local file plus the normal encrypted iPhone backup are the copies. Export writes the whole document (glucose, meals, bounds, decision, applied factors, logs, announcements). Import replaces the learning state with that document and keeps the previous file as `rheos-state.pre-import-*.json`.

CloudKit is not used. It would be another container in the same iCloud capability and is unnecessary for a single JSON file.

## Files

New code is under `Trio/Sources/Rheos/` and `RheosPackage/` (tests for the core).

Existing files touched only to show the screen, start the logger, or call the one profile hook:

- `Trio/Sources/APS/OpenAPS/OpenAPS.swift` — the hook
- `Trio/Sources/Router/Screen.swift` — navigation
- `Trio/Sources/Modules/Settings/SettingItems.swift` — settings row
- `Trio/Sources/Assemblies/ServiceAssembly.swift` — register the coordinator
- `Trio/Sources/Application/TrioApp.swift` — start it after Core Data
- `Trio/Sources/Modules/Home/View/HomeRootView.swift` — status and one-tap return to Schatten
- `Trio/Sources/Modules/Home/View/Header/LoopStatusView.swift` — same control on the loop status sheet
- `Trio/Resources/Info.plist` — Health read usage text
- `Trio.xcodeproj/project.pbxproj` — compile the new Swift files

Not changed: dosing engine, SMB settings, autosens generator, device managers, entitlements, Fastlane, GitHub workflows. HealthKit was already entitled. No new capability is required. The first time Schatten or Scharf is enabled, iOS asks for read access to the wearable types. If the sheet does not list them, enable them in Settings → Health → Data Access → Trio.
