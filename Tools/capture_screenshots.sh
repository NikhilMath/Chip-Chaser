#!/bin/zsh
# Takes the App Store screenshot set on one simulator, with demo data and demo chip photos.
# usage: Tools/capture_screenshots.sh <simulator udid> <out dir> [display]
#   iPhone 18 Pro -> docs/appstore/6.3in, iPhone 18 Pro Max -> docs/appstore,
#   iPhone Duo folded -> docs/appstore/duo (display 1), unfolded -> docs/appstore/duo-unfolded (display 3).
set -e
export DEVELOPER_DIR=${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}
ROOT=${0:A:h:h}; DEV=$1; OUT=${2:A}; DISP=${3:-}
BID=com.nikhilmath.HarleyChipTracker
WORK=${TMPDIR:-/tmp}/chip-chaser-screenshots
if [[ ! -d $WORK/photos ]]; then swift $ROOT/Tools/make_demo_chip_photos.swift $ROOT/HarleyChipTracker/Resources/dealers.json $WORK/photos; fi
if [[ ! -d $WORK/dd/Build/Products/Debug-iphonesimulator ]]; then
  xcodebuild -project $ROOT/HarleyChipTracker.xcodeproj -scheme HarleyChipTracker -configuration Debug \
    -destination 'generic/platform=iOS Simulator' -derivedDataPath $WORK/dd -allowProvisioningUpdates build -quiet
fi
APP=$(ls -d $WORK/dd/Build/Products/Debug-iphonesimulator/*.app)
mkdir -p $OUT
xcrun simctl install $DEV $APP
xcrun simctl location $DEV set 43.0389,-87.9065
xcrun simctl status_bar $DEV override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3 --dataNetwork wifi
xcrun simctl privacy $DEV grant location-always $BID 2>/dev/null || xcrun simctl privacy $DEV grant location $BID
DATA=$(xcrun simctl get_app_container $DEV $BID data)
rm -rf "$DATA/tmp/Demo Chip Photos"; mkdir -p "$DATA/tmp/Demo Chip Photos"
cp $WORK/photos/* "$DATA/tmp/Demo Chip Photos/"
shot() {
  local name=$1; shift
  xcrun simctl terminate $DEV $BID 2>/dev/null || true
  xcrun simctl launch $DEV $BID -demoData YES "$@" >/dev/null
  sleep 7
  xcrun simctl io $DEV screenshot ${DISP:+--display=$DISP} $OUT/$name.png >/dev/null 2>&1
}
shot 1-map
shot 2-collection -debugTab collection
shot 3-dealers -debugTab dealers
shot 4-detail -debugTab dealers -debugDealer hd-210
shot 5-progress -debugTab progress
ls $OUT
