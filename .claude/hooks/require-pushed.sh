#!/bin/bash
# Claude Code Stop hook: don't finish a turn with work that isn't on GitHub or
# hasn't been released.
# Blocks once with a reason when there are uncommitted changes, commits that
# aren't on origin/main, or app changes since the last uploaded build (the
# newest v*-build* tag); never blocks twice in a row (stop_hook_active).

input=$(cat)
if printf '%s' "$input" | jq -e '.stop_hook_active == true' >/dev/null 2>&1; then
  exit 0
fi

cd "${CLAUDE_PROJECT_DIR:-.}" 2>/dev/null || exit 0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

problems=()
changed=$(git status --porcelain | wc -l | tr -d ' ')
[ "$changed" -gt 0 ] && problems+=("$changed uncommitted file(s)")
ahead=$(git rev-list --count origin/main..HEAD 2>/dev/null || echo 0)
[ "$ahead" -gt 0 ] && problems+=("$ahead commit(s) not on origin/main")

if [ ${#problems[@]} -gt 0 ]; then
  summary=$(printf '%s, ' "${problems[@]}"); summary=${summary%, }
  jq -n --arg r "Not on GitHub yet: $summary. Commit the work and push it to origin main (git push origin HEAD:main) before finishing, unless the user asked to hold off." \
    '{decision: "block", reason: $r}'
  exit 0
fi

# Everything is pushed. Did the app itself change since the last uploaded build?
git fetch -q origin --tags 2>/dev/null
released=$(git describe --tags --abbrev=0 --match 'v*-build*' HEAD 2>/dev/null) || exit 0
app_files=$(git diff --name-only "$released" HEAD -- HarleyChipTracker Config HarleyChipTracker.xcodeproj | wc -l | tr -d ' ')
[ "$app_files" -gt 0 ] || exit 0

if [ -f .github/workflows/release.yml ]; then
  # GitHub uploads and releases on push. Only speak up if its latest run failed.
  last=$(gh run list --workflow release.yml --branch main --limit 1 --json conclusion,url \
    --jq '.[0] | select(.conclusion == "failure") | .url' 2>/dev/null)
  [ -n "$last" ] || exit 0
  reason="$app_files app file(s) changed since $released, and the GitHub release workflow failed ($last). Check it with gh run view --log-failed, fix it and re-run (gh workflow run release.yml), or upload from this Mac with Tools/release.sh. Say so if it can't be fixed now, unless the user asked to hold off."
else
  reason="$app_files app file(s) changed since $released, the last uploaded build. Run Tools/release.sh (with DEVELOPER_DIR set) to upload a new build and publish its GitHub Release before finishing, unless the user asked to hold off or the change isn't ready to ship."
fi
jq -n --arg r "$reason" '{decision: "block", reason: $r}'
exit 0
