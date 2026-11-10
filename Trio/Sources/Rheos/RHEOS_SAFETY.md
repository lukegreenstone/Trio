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

Context modes (Showtime, Urlaub, Krank, Fasten, Sport) only name a preset the user already saved. Confirmation calls Trio's existing `AdjustmentManager`. Rheos does not choose a percentage or a target. If no preset with that name exists, nothing is activated.

Meal outcomes can be marked as seen. That writes a flag in the Rheos log only.

The chat stub answers from the on-device report. It has no network client. Body data never becomes an insulin number.

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
