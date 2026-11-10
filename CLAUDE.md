# Chip Chaser: notes for Claude

## Shipping is automatic. Keep it that way.

The user wants releases to need nothing from them. GitHub does the uploading and submitting
(`.github/workflows/release.yml`, README → Releasing); your job is to leave the repo in a state
where the next push ships what it should. After every app change:

1. **Commit and push to `main`.** That alone tests the app, uploads a build to TestFlight and
   publishes a GitHub Release.
2. **Make sure the version can take the build.** Read `MARKETING_VERSION` in the Xcode project.
   If that version is already live on the App Store, Apple refuses new builds for it, so raise
   it (1.4 → 1.5, or 1.4.1 for a fix) in the same push.
3. **Write what's new.** Put a short, plain-language list of what changed for users in
   `docs/appstore/whats-new/<version>.txt` (under 4,000 characters, no internal jargon). This
   file is the go-ahead to submit that version for App Review, so only add it once the work
   is finished and has no known bugs. Keep adding to it while the version is still in progress.
4. **Check the run** with `gh run list --repo NikhilMath/Chip-Chaser --workflow release.yml`.
   If it failed, fix it and push again. If the submit step says it didn't submit, tell the
   user why in one line:
   - another version is still with Apple: nothing to do. The daily "Submit waiting version"
     workflow (`submit-waiting.yml`) submits it once that version is live;
   - Apple rejected a version: the user has to read why in App Store Connect.
5. **Screens changed?** Retake the App Store screenshots in `docs/appstore/` (Tools/capture_screenshots.sh)
   and remind the user to upload them in App Store Connect; the workflow can't do that part.

Never put the App Store Connect key (`.p8`) in the repo, a command line or a message. It lives
in the repo's Actions secrets (ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8); the user keeps the file.

## Other rules

- `HarleyChipTracker/Resources/dealers.json` on `main` is downloaded by installed apps (1.4+)
  once a day. Committing it ships it: run the dealer tests first and never drop a dealer ID.
- SwiftData models are add-only, and the store path never moves: users' chips must survive
  every update (README → Keeping collections safe across updates).
- Build with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` and
  `-allowProvisioningUpdates`.
