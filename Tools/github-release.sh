#!/bin/zsh
# Tags an uploaded build and publishes it as a GitHub Release.
#
#   Tools/github-release.sh <build> [commit]
#
# The commit (default HEAD) is the one the build was made from. The tag is
# v<version>-build<build>, with the version read from the project file at that
# commit, and the notes list the commits since the previous build's tag.
# The release workflow (.github/workflows/release.yml) and Tools/release.sh run
# this after every upload.
set -euo pipefail
cd "${0:A:h}/.."

build=${1:?usage: Tools/github-release.sh <build> [commit]}
commit=$(git rev-parse --verify "${2:-HEAD}^{commit}")
project=HarleyChipTracker.xcodeproj/project.pbxproj
version=$(git show "$commit:$project" | grep -m1 -o 'MARKETING_VERSION = [0-9.]*' | grep -o '[0-9.]*$')
tag="v$version-build$build"
title="Chip Chaser $version (build $build)"

previous=$(git describe --tags --abbrev=0 --match 'v*-build*' "$commit^" 2>/dev/null || true)

if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  echo "Tag $tag already exists."
else
  git tag -a "$tag" -m "$title" "$commit"
fi
git push -q origin "refs/tags/$tag"

if [[ -n "$previous" ]]; then
  changes=$(git log --no-merges --format='- %s' "$previous..$commit" | grep -v '^- Upload build ' || true)
  changes="Changes since $previous:"$'\n\n'"${changes:-- No app changes; rebuilt only.}"
else
  changes="First build tracked with a GitHub Release."
fi
notes="Uploaded to App Store Connect as $title. It appears in TestFlight once Apple finishes processing it."$'\n\n'"$changes"

if gh release view "$tag" >/dev/null 2>&1; then
  echo "GitHub Release $tag already exists."
else
  gh release create "$tag" --verify-tag --latest --title "$title" --notes "$notes"
fi
