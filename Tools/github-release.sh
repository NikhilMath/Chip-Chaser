#!/bin/zsh
# Tags an uploaded build and publishes it as a GitHub Release.
#
#   Tools/github-release.sh [commit]
#
# The commit (default HEAD) is the "Upload build N" commit that Tools/release.sh
# makes. The tag is v<version>-build<N>, read from the project file at that
# commit, and the notes list the commits since the previous build's tag.
# Tools/release.sh runs this after every upload.
set -euo pipefail
cd "${0:A:h}/.."

commit=$(git rev-parse --verify "${1:-HEAD}^{commit}")
project=HarleyChipTracker.xcodeproj/project.pbxproj
settings=$(git show "$commit:$project")
version=$(print -r -- "$settings" | grep -m1 -o 'MARKETING_VERSION = [0-9.]*' | grep -o '[0-9.]*$')
build=$(print -r -- "$settings" | grep -m1 -o 'CURRENT_PROJECT_VERSION = [0-9]*' | grep -o '[0-9]*$')
tag="v$version-build$build"
title="Chip Chaser $version (build $build)"

if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
  echo "Tag $tag already exists." >&2
else
  git tag -a "$tag" -m "$title" "$commit"
fi
git push -q origin "refs/tags/$tag"

previous=$(git describe --tags --abbrev=0 --match 'v*-build*' "$commit^" 2>/dev/null || true)
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
