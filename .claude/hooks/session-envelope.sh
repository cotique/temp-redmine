#!/usr/bin/env bash
# SessionStart + PreCompact hook — keep the operating state across compaction.
#
# Compaction preserves conclusions and drops the operating state: branch, base,
# worktree, repo scope, "don't touch X". Two events, one asset:
#
#   PreCompact   -> persist the envelope to .claude/session-state.json and count
#                   the compaction. Prints nothing.
#   SessionStart -> print the envelope as session context, including how many
#                   compactions this session has already been through.
#
# Compaction itself stays automatic and cannot be cancelled — that is fine. The
# harm was never the timing, it was the asymmetric loss: the summary keeps the
# conclusions and drops the state. Persisted state makes the timing irrelevant.
#
# What this does NOT restore: the provenance of claims. "X was [INFERRED], not
# [OBSERVED]" lives in the conversation text, and a summary flattens it into an
# apparent fact. That half is handled by tagging claims inline — a tag attached
# to the claim survives summarising; a disclaimer beside it does not.
#
# config: .claude/discipline.json →
#   "envelope": {
#     "repos": [".", "../sibling-service"],
#     "notes": ["never touch the shared release branch", "artifact = patch, not PR"]
#   }
# deps: jq, git

set -u
. "$(dirname "$0")/_events.sh"
payload=$(cat 2>/dev/null || true)

# Which event this is decides whether we persist or print, so it must not be
# readable only when jq happens to be installed. Measured: with jq absent the
# parsed value came back empty, PreCompact fell through to the SessionStart
# branch, and the asset printed instead of saving — the compaction counter stayed
# at zero forever while the hook looked like it was working. A dependency that is
# missing must not read as an asset that is fine.
case "$(printf '%s' "$payload" | tr -d ' \n\t')" in
  *'"hook_event_name":"PreCompact"'*) event=PreCompact ;;
  *) event=$(printf '%s' "$payload" | jq -r '.hook_event_name // empty' 2>/dev/null | tr -d '\r') ;;
esac
DISC_SESSION_ID=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null | tr -d '\r')
export DISC_SESSION_ID
source_name=$(printf '%s' "$payload" | jq -r '.source // empty' 2>/dev/null | tr -d '\r')

proj="${CLAUDE_PROJECT_DIR:-.}"
config="$proj/.claude/discipline.json"
state="$proj/.claude/session-state.json"

repos=""
notes=""
if [ -f "$config" ]; then
  repos=$(jq -r '.envelope.repos[]?' "$config" 2>/dev/null | tr -d '\r')
  notes=$(jq -r '.envelope.notes[]?' "$config" 2>/dev/null | tr -d '\r')
fi
[ -z "$repos" ] && repos="."

envelope() {
  while IFS= read -r rel; do
    [ -z "$rel" ] && continue
    dir="$proj/$rel"
    [ "$rel" = "." ] && dir="$proj"
    if ! git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      echo "  $rel: not a git worktree (or missing)"
      continue
    fi
    branch=$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null)
    head=$(git -C "$dir" rev-parse --short HEAD 2>/dev/null)
    dirty=$(git -C "$dir" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    wt=$(git -C "$dir" worktree list 2>/dev/null | wc -l | tr -d ' ')
    line="  $rel: branch=$branch head=$head uncommitted=$dirty"
    [ "$wt" -gt 1 ] && line="$line worktrees=$wt (confirm which one you are in)"
    echo "$line"
  done <<< "$repos"
  if [ -n "$notes" ]; then
    echo "  standing constraints:"
    while IFS= read -r n; do
      [ -n "$n" ] && echo "    - $n"
    done <<< "$notes"
  fi
}

# A new session id starts the count over; a long-running session accumulates.
compactions=0
if [ -f "$state" ]; then
  prev_session=$(jq -r '.sessionId // empty' "$state" 2>/dev/null | tr -d '\r')
  if [ -n "$DISC_SESSION_ID" ] && [ "$prev_session" = "$DISC_SESSION_ID" ]; then
    compactions=$(jq -r '.compactions // 0' "$state" 2>/dev/null | tr -d '\r')
  fi
fi

if [ "$event" = "PreCompact" ]; then
  # Persisting needs jq to build the file. Without it the state cannot be saved,
  # and the one thing that must not happen is saving nothing quietly: the next
  # session would read a zero counter as "no compactions yet".
  if ! command -v jq >/dev/null 2>&1; then
    echo "[session-envelope] jq is missing, so the envelope was NOT saved across this compaction." >&2
    echo "[session-envelope] Re-derive branch, base and repo scope after the summary; do not trust the counter." >&2
    disc_log session-envelope degraded fired "jq missing: envelope not persisted"
    exit 0
  fi
  compactions=$((compactions + 1))
  mkdir -p "$(dirname "$state")" 2>/dev/null
  jq -n --arg s "$DISC_SESSION_ID" --argjson c "$compactions" \
        --arg t "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg e "$(envelope)" \
        '{sessionId:$s, compactions:$c, savedAt:$t, envelope:($e|split("\n"))}' \
        > "$state" 2>/dev/null || true
  disc_log session-envelope persist fired "compaction $compactions"
  exit 0
fi

disc_log session-envelope ground fired "$source_name"

echo "[operational envelope - re-read this instead of recalling it]"
envelope
if [ "$compactions" -gt 0 ]; then
  echo "  compactions so far in this session: $compactions"
  if [ "$compactions" -ge 3 ]; then
    echo "  Retractions and dropped instructions cluster right after a compaction."
    echo "  A clean boundary (change verified and committed) is a cheap place to start fresh."
  fi
fi
echo "  Treat the above as current state, not as history: re-run these checks"
echo "  before any mutation if the conversation has been compacted since."

# Dependency report, once per session. Measured on a machine without jq: four of
# the five gates exited 0 and printed nothing — a push to a protected branch and a
# literal secret both sailed through, and the setup was indistinguishable from one
# where the rules simply allowed it. Guardrails that vanish quietly are worse than
# absent ones, because their presence is still being counted on.
#
# Announcing here rather than blocking in each hook is deliberate: a PreToolUse
# gate that exits 2 on a missing dependency would refuse every Bash call in the
# session, which is a far larger failure than the one it reports. One loud
# statement at session start, no gate that fires on work it cannot judge.
if ! command -v jq >/dev/null 2>&1; then
  echo "  DEPENDENCY MISSING: jq is not installed. Current state of the bash hooks:"
  echo "    REDUCED  block-protected-branch - built-in branch list only, no config"
  echo "    REDUCED  secret-guard - built-in detectors only, no custom patterns"
  echo "    INERT    format-postcheck, kb-first-reminder"
  echo "    dod-gate still reports; the envelope above is NOT persisted across compaction"
  echo "  Install jq, or use the PowerShell twins, which need no external parser."
  disc_log session-envelope degraded fired "jq missing: enforcement hooks inert"
fi
exit 0
