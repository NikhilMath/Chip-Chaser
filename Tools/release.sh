#!/bin/zsh
# Uploads a build to App Store Connect from this Mac and publishes its GitHub Release.
#
#   Tools/release.sh
#
# Normally GitHub does this on every push that changes the app
# (.github/workflows/release.yml); this is the fallback for when that can't run.
# Refuses to run unless everything is committed and on origin/main. The build
# number comes from the release tags (Tools/next-build-number.sh) and is passed
# to xcodebuild, so nothing gets committed. Changed the SwiftData models?
# Deploy the CloudKit schema to production first (see README).
set -euo pipefail
cd "${0:A:h}/.."

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export PATH="$DEVELOPER_DIR/usr/bin:$PATH"

git fetch -q origin --tags
if [[ -n "$(git status --porcelain)" ]]; then
  echo "Commit your changes first; only pushed work gets released." >&2; exit 1
fi
if [[ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]]; then
  echo "HEAD isn't origin/main. Push (git push origin HEAD:main) or pull first." >&2; exit 1
fi

build=$(Tools/next-build-number.sh)
echo "Uploading build $build"

# Outside ~/Documents: iCloud Drive can tag build products with Finder metadata
# that breaks code signing.
work=$(mktemp -d -t harley-release)
trap 'rm -rf "$work"' EXIT
xcodebuild archive -project HarleyChipTracker.xcodeproj -scheme HarleyChipTracker \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "$work/HarleyChipTracker.xcarchive" -derivedDataPath "$work/DerivedData" \
  -allowProvisioningUpdates -quiet CURRENT_PROJECT_VERSION="$build"
xcodebuild -exportArchive -archivePath "$work/HarleyChipTracker.xcarchive" \
  -exportOptionsPlist Config/ExportOptions.plist -exportPath "$work/export" \
  -allowProvisioningUpdates

if ! Tools/github-release.sh "$build" HEAD; then
  echo "Build $build uploaded, but the GitHub Release didn't work. Retry with: Tools/github-release.sh $build HEAD" >&2
  exit 1
fi
echo "Uploaded build $build and published its GitHub Release. Add it to a TestFlight group in App Store Connect once it finishes processing."
