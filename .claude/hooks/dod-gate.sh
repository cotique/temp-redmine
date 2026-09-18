#!/usr/bin/env bash
# Stop hook — "definition of done" gate.
#
# When the session leaves uncommitted changes matching dod.fileGlobs, run the
# configured checks (build, tests, lint...). Any failure blocks the stop
# (exit 2) so Claude has to fix the state before finishing the turn.
#
# stdin:  hook payload JSON ({ stop_hook_active: bool, ... })
# config: .claude/discipline.json →
#   "dod": {
#     "fileGlobs": ["*.cs"],
#     "checks": [ { "name": "build", "command": "dotnet build -warnaserror" } ]
#   }
# deps: jq, git

set -u
. "$(dirname "$0")/_events.sh"

payload=$(cat)

# The loop guard must not depend on the thing it guards against. Below, a missing
# jq is a deliberate exit 2; if that verdict can be reached while this guard is
# unreachable, the stop loop never terminates — measured at seventeen consecutive
# turns. So read stop_hook_active without a parser. Substring matching on
# whitespace-stripped JSON is looser than jq and knowingly so: that looseness is
# the price of a guard that still works once the parser is gone.
case "$(printf '%s' "$payload" | tr -d ' \n\t')" in
  *'"stop_hook_active":true'*) exit 0 ;;
esac

proj="${CLAUDE_PROJECT_DIR:-.}"
config="$proj/.claude/discipline.json"

# Jurisdiction before dependencies. A gate must establish that this session is
# its business before it reports anything at all — including its own broken
# setup. Reporting a missing dependency to a session the gate would have passed
# on regardless is a false intercept, and a gate that fires on work it has no
# claim to is how gates get switched off. All three checks are jq-free by
# construction, so they survive exactly the failure mode below.
[ -f "$config" ] || exit 0
git -C "$proj" rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0
# A clean tree cannot match any fileGlob, so exiting here is equivalent to
# exiting at the glob check further down — minus the config reads that need jq.
[ -n "$(git -C "$proj" status --porcelain 2>/dev/null)" ] || exit 0

# Checked rather than assumed: every config read below goes through jq, and each
# one is written to fail soft. With jq absent they all fail, so "the tool is
# missing" and "nothing is configured" produce the identical silent pass — the
# gate stops existing instead of reporting an error. A missing dependency must
# never read as a passing verdict. Reached only once jurisdiction is established:
# config present, inside a repo, changes pending, and nothing to read them with.
command -v jq >/dev/null 2>&1 || {
  echo "[dod-gate] jq is not installed, so the checks cannot be read. This is not a pass." >&2
  exit 2
}

DISC_SESSION_ID=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null | tr -d '\r')
export DISC_SESSION_ID

jq -e '.dod.checks | length > 0' "$config" >/dev/null 2>&1 || exit 0

# Any uncommitted (staged or unstaged) file matching a DoD glob?
mapfile -t globs < <(disc_jq_lines '.dod.fileGlobs[]?' "$config")
[ "${#globs[@]}" -eq 0 ] && globs=("*")

touched=0
while IFS= read -r f; do
  [ -z "$f" ] && continue
  base=$(basename "$f")
  for g in "${globs[@]}"; do
    # shellcheck disable=SC2254
    case "$base" in $g) touched=1; break 2 ;; esac
  done
done < <(git -C "$proj" status --porcelain | sed 's/^...//; s/.* -> //')

[ "$touched" -eq 0 ] && exit 0

start_ms=$(( $(date +%s) * 1000 ))

# Preconditions run before any check, and their failure is reported as its own
# thing rather than as a verdict on the changes. Without this the gate says
# "definition-of-done checks failed" when the real cause is a stopped Docker
# daemon, and the reader goes hunting through diffs for a fault that is not
# there. A wrong reason costs more than a wrong verdict: it sends the search in
# the wrong direction, and gates that do that get switched off. It still blocks
# — unverified work is unverified — but it blocks saying what to start rather
# than what to fix.
while IFS=$'\t' read -r pre_name pre_cmd pre_remedy; do
  [ -z "$pre_cmd" ] && continue
  if ! (cd "$proj" && eval "$pre_cmd" >/dev/null 2>&1); then
    pre_ms=$(( $(date +%s) * 1000 - start_ms ))
    detail="precondition '${pre_name}' unavailable"
    if [ "$(disc_mode)" = "shadow" ]; then
      disc_log dod-gate would-block precondition "$detail" "$pre_ms"
      echo "[dod-gate] SHADOW: cannot run the checks — $detail" >&2
      exit 0
    fi
    disc_log dod-gate precondition-failed precondition "$detail" "$pre_ms"
    {
      echo "[dod-gate] Cannot run the checks: ${detail}."
      echo "This is not a verdict on your changes — the checks did not run."
      [ -n "$pre_remedy" ] && echo "$pre_remedy"
    } >&2
    exit 2
  fi
done < <(disc_jq_lines '.dod.preconditions[]? | [.name, .command, (.remedy // "")] | @tsv' "$config")

failures=""
while IFS=$'\t' read -r name check_cmd; do
  [ -z "$check_cmd" ] && continue
  if ! (cd "$proj" && eval "$check_cmd" >/tmp/dod-gate-out.$$ 2>&1); then
    failures="${failures}
--- ${name} FAILED ---
$(tail -n 30 /tmp/dod-gate-out.$$)"
  fi
  rm -f /tmp/dod-gate-out.$$
done < <(disc_jq_lines '.dod.checks[] | [.name, .command] | @tsv' "$config")
# durationMs is the gate's price: what it costs at every session end. Weigh it
# against intercepts when deciding whether the gate keeps its place.
duration_ms=$(( $(date +%s) * 1000 - start_ms ))

if [ -n "$failures" ]; then
  if [ "$(disc_mode)" = "shadow" ]; then
    disc_log dod-gate would-block fail "$(printf '%s' "$failures" | head -3 | tr '\n' ';')" "$duration_ms"
    {
      echo "[dod-gate] SHADOW (not enforced): definition-of-done checks failed:"
      echo "$failures"
    } >&2
    exit 0
  fi
  disc_log dod-gate block fail "" "$duration_ms"
  {
    echo "[dod-gate] Definition-of-done checks failed for uncommitted changes:"
    echo "$failures"
    echo
    echo "Fix the failures (or revert the changes) before ending the session."
  } >&2
  exit 2
fi
disc_log dod-gate pass pass "" "$duration_ms"
exit 0
