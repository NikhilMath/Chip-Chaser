#!/bin/bash
# Claude Code Stop hook: don't finish a turn with work that isn't on GitHub.
# Blocks once with a reason when there are uncommitted changes or commits that
# aren't on origin/main; never blocks twice in a row (stop_hook_active).

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
fi
exit 0
