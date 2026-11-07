#!/bin/zsh
# Prints the next build number: one more than the highest v*-build<N> release tag
# (or the project file's CURRENT_PROJECT_VERSION, if that's higher).
#
# Release tags are the record of what was uploaded, so GitHub Actions and
# Tools/release.sh never reuse a number. Fetch tags first (git fetch --tags).
set -euo pipefail
cd "${0:A:h}/.."

highest=$(grep -m1 -o 'CURRENT_PROJECT_VERSION = [0-9]*' HarleyChipTracker.xcodeproj/project.pbxproj | grep -o '[0-9]*$')
for tag in $(git tag -l 'v*-build*'); do
  n=${tag##*-build}
  [[ $n == <-> ]] && (( n > highest )) && highest=$n
done
print $(( highest + 1 ))
