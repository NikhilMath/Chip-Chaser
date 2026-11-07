# Chip Chaser

Chip Chaser is an iPhone app for Harley-Davidson chip collectors (it started out as Harley Chip Tracker, the name the code still uses). Every Harley-Davidson dealership sells its own poker chip; this app lists them all and tracks which ones you have and which you're still missing.

<p>
  <img src="docs/screenshots/dealers.png" width="200" alt="Dealer list grouped by state">
  <img src="docs/screenshots/map.png" width="200" alt="Map of collected and missing chips">
  <img src="docs/screenshots/progress.png" width="200" alt="Collection progress">
  <img src="docs/screenshots/detail.png" width="200" alt="Dealer detail with chip count">
</p>

## Features

- **Every location, built in.** 648 US and Canadian locations (556 dealerships, 26 satellite stores, 66 apparel & gift shops) from Harley-Davidson's dealer locator, including Alaska, Hawaii, Puerto Rico and Guam.
- **Mark chips in one tap.** Tap the chip next to a dealer, or swipe the row. Filter by All / Missing / Collected, search by name, city, state or ZIP, and sort by state, A to Z, or nearest to you.
- **Map.** Orange chips are ones you have, grey ones you're missing. The map opens on your area so you can plan a ride around the chips you still need.
- **Progress.** Overall percentage, per-state progress (with a seal when you finish a state), recently collected, and counts of extras.
- **Trading.** Track how many of each chip you own. Share your *missing list* or *extras for trade* as text to a collector group.
- **Your own stores.** Add a dealer that's new, closed, or overseas; it counts like any other.
- **Choose what counts.** Turn Canadian locations, satellite stores or apparel shops on or off in Settings.
- **Saved to your Apple ID.** Your collection syncs through your own iCloud account to every iPhone signed in with the same Apple ID. There's no separate sign-in; Settings shows whether iCloud is on.
- **Backup.** Export your collection as a JSON file (Files, AirDrop) and import it on any phone.

## iCloud sync

The SwiftData store mirrors to the private CloudKit database in `iCloud.com.nikhilmath.HarleyChipTracker` (see `HarleyChipTracker/Services/CloudSync.swift`). Each collector's data lives in their own iCloud account; the developer can't read it. Without an iCloud account the app keeps working locally and syncs once the person signs in.

CloudKit can't enforce one record per dealer, so the app merges duplicates (the same chip marked on two devices before they sync) whenever iCloud changes arrive.

**When the models change:** TestFlight and App Store builds use CloudKit's *production* environment, which only gets new record types or fields when you deploy them.

1. Bump `CloudSync.schemaVersion`, then run a Debug build on a device signed in to iCloud. It pushes the schema to the *development* environment on first launch (or pass `-initCloudKitSchema YES`).
2. In [CloudKit Console](https://icloud.developer.apple.com/dashboard), open the container and choose **Deploy Schema Changes** to production.
3. Then archive and upload the build.

Only add fields; never rename or delete one that has shipped.

## Running it

Requirements: Xcode 16 or later (built with Xcode 27.2), iOS 18 or later.

1. Open `HarleyChipTracker.xcodeproj`.
2. Pick an iPhone simulator and press **Run**.
3. To install on your own iPhone, select the *HarleyChipTracker* target → **Signing & Capabilities** → choose your Team, then run on your device.

From the command line:

```bash
xcodebuild test -project HarleyChipTracker.xcodeproj -scheme HarleyChipTracker -destination 'platform=iOS Simulator,name=iPhone 18 Pro'
```

Debug builds accept `-demoData YES` (in-memory sample collection), `-debugTab map|progress|settings` and `-debugDealer <id>` launch arguments for screenshots.

## Releasing to TestFlight

```bash
Tools/release.sh
```

The script only runs when everything is committed and on `origin/main`. It bumps the build number, archives, uploads with `Config/ExportOptions.plist`, then commits and pushes the bump, so every TestFlight build matches a commit on GitHub. When processing finishes, add the build to a group in App Store Connect → TestFlight. The **Friends** group has the public link, and Apple has to review its builds.

Working with Claude Code in this repo, a Stop hook (`.claude/hooks/require-pushed.sh`) won't let a turn end while changes are uncommitted or commits aren't on `origin/main`.

## Updating the dealer list

Dealers open, close and get renamed. To refresh the bundled list:

```bash
python3 Tools/update_dealers.py
```

The script runs about 150 radius searches against Harley-Davidson's public dealer locator, de-duplicates them, and rewrites `HarleyChipTracker/Resources/dealers.json`, keeping only the fields the app uses. Chip records are keyed by Harley-Davidson's dealer ID, so a refresh never loses anyone's collection.

## Project layout

```
HarleyChipTracker/
  App/          App entry point and AppModel (tracking settings, location)
  Models/       Dealer, ChipRecord / CustomDealer (SwiftData), region names
  Data/         Bundled directory loader, collection status, backup, share text
  Services/     One-shot location provider, iCloud sync and account status
  Views/        Dealers, Map, Progress, Settings, detail and add-store screens
  Resources/    dealers.json
HarleyChipTrackerTests/   Swift Testing suite
Config/         Entitlements (iCloud, push), Info.plist additions, TestFlight export options
Tools/          update_dealers.py, make_icon.swift (app icon), release.sh (TestFlight upload)
```

## Disclaimer

Chip Chaser is an independent fan project. It is not affiliated with, sponsored by, or endorsed by Harley-Davidson. Harley-Davidson and related marks are trademarks of H-D U.S.A., LLC. Location data comes from Harley-Davidson's public dealer locator.
