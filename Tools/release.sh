#!/bin/zsh
# Uploads a new build to App Store Connect (TestFlight).
#
#   Tools/release.sh
#
# Refuses to run unless everything is committed and on origin/main, bumps the
# build number, archives, uploads, then commits and pushes the bump. Changed the
# SwiftData models? Deploy the CloudKit schema to production first (see README).
set -euo pipefail
cd "${0:A:h}/.."

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export PATH="$DEVELOPER_DIR/usr/bin:$PATH"

git fetch -q origin
if [[ -n "$(git status --porcelain)" ]]; then
  echo "Commit your changes first; only pushed work gets released." >&2; exit 1
fi
if [[ "$(git rev-parse HEAD)" != "$(git rev-parse origin/main)" ]]; then
  echo "HEAD isn't origin/main. Push (git push origin HEAD:main) or pull first." >&2; exit 1
fi

project=HarleyChipTracker.xcodeproj/project.pbxproj
current=$(grep -m1 -o 'CURRENT_PROJECT_VERSION = [0-9]*' "$project" | grep -o '[0-9]*$')
next=$((current + 1))
sed -i '' "s/CURRENT_PROJECT_VERSION = $current;/CURRENT_PROJECT_VERSION = $next;/g" "$project"
echo "Build $current → $next"

# Outside ~/Documents: iCloud Drive can tag build products with Finder metadata
# that breaks code signing.
work=$(mktemp -d -t harley-release)
trap 'rm -rf "$work"' EXIT
if ! xcodebuild archive -project HarleyChipTracker.xcodeproj -scheme HarleyChipTracker \
      -configuration Release -destination 'generic/platform=iOS' \
      -archivePath "$work/HarleyChipTracker.xcarchive" -derivedDataPath "$work/DerivedData" \
      -allowProvisioningUpdates -quiet \
   || ! xcodebuild -exportArchive -archivePath "$work/HarleyChipTracker.xcarchive" \
      -exportOptionsPlist Config/ExportOptions.plist -exportPath "$work/export" \
      -allowProvisioningUpdates; then
  git checkout -- "$project"
  echo "Release failed; build number left at $current." >&2; exit 1
fi

git commit -q -m "Upload build $next to TestFlight" -- "$project"
git push -q origin HEAD:main
echo "Uploaded build $next and pushed the bump. Add it to a TestFlight group in App Store Connect once it finishes processing."
