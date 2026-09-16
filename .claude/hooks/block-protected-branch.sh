#!/usr/bin/env bash
# PreToolUse hook (matcher: Bash) — blocks destructive git operations that would
# modify a protected branch.
#
# stdin:  Claude Code hook payload JSON ({ tool_input: { command: "..." } })
# exit 0: allow    exit 2: block (stderr is fed back to Claude)
# deps:   jq, git
#
# Protected branch patterns come from .claude/discipline.json (protectedBranches),
# falling back to: main, master, develop, release/*

set -u
. "$(dirname "$0")/_events.sh"
payload=$(cat)

# REDUCED mode. This is a PreToolUse gate on Bash, so exiting 2 because jq is
# missing would refuse every shell command in the session — a far larger failure
# than the one it reports. Vanishing silently is worse still: a push to main went
# through and the setup was indistinguishable from one where the rules allowed it.
# So keep the gate alive on its built-in defaults, and label the verdict.
degraded=""
if disc_have_jq; then
  DISC_SESSION_ID=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null | tr -d '\r')
  cmd=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null | tr -d '\r')
else
  degraded=1
  DISC_SESSION_ID=$(printf '%s' "$payload" | disc_field_crude session_id)
  cmd=$(printf '%s' "$payload" | disc_field_crude command)
fi
[ -z "$cmd" ] && exit 0
case "$cmd" in *git*) ;; *) exit 0 ;; esac

proj="${CLAUDE_PROJECT_DIR:-.}"
config="$proj/.claude/discipline.json"
branches=""
block_all_push=""
if [ -f "$config" ] && disc_have_jq; then
  # Multi-line, so read it line-wise: $() strips only the final carriage return,
  # and without this only the last protected branch was enforced on Windows.
  branches=$(disc_jq_lines '.protectedBranches[]?' "$config")
  block_all_push=$(jq -r 'if .blockAllPush then "1" else "" end' "$config" 2>/dev/null | tr -d '\r')
fi
[ -z "$branches" ] && branches=$'main\nmaster\ndevelop\nrelease/*'

is_protected() {
  local b="$1" pat
  while IFS= read -r pat; do
    [ -z "$pat" ] && continue
    # shellcheck disable=SC2254
    case "$b" in $pat) return 0 ;; esac
  done <<< "$branches"
  return 1
}

# Pushes are WARNED about here and REFUSED by the pre-push git hook, which git
# hands the real refs on stdin. This gate only ever sees the text of a command that
# has not run, and every defect it had was the same defect: no model of shell
# structure. Corrected once for quoting, once for separators, with `$(...)`,
# `bash -c`, xargs and multi-line scripts still ahead. A false positive in an
# advisory layer costs a sentence; in a blocking layer it costs a session, and that
# is how gates get switched off.
#
# `exit 2` is kept for exactly what pre-push cannot see: a commit landing on a
# protected branch, and a local branch deletion. Neither reaches a remote, so git
# never offers a hook with authoritative data.
warn_push() {  # $1 = reason
  disc_log block-protected-branch warn-push fail "$1"
  echo "[block-protected-branch] $1" >&2
  echo "The pre-push hook will refuse this; it reads the real refs from git." >&2
  echo "If it is not installed in this repo, nothing else will stop it — run apply." >&2
  [ -n "$degraded" ] && echo "(REDUCED: jq is missing, so this ran on the built-in branch list.)" >&2
  exit 0
}

block() {
  if [ "$(disc_mode)" = "shadow" ]; then
    # Shadow: record what would have been stopped, let it through. One window of
    # this proves the gate's value before it can annoy anyone.
    disc_log block-protected-branch would-block fail "$1"
    echo "[block-protected-branch] SHADOW (not enforced): $1" >&2
    exit 0
  fi
  disc_log block-protected-branch block fail "$1"
  echo "[block-protected-branch] BLOCKED: $1" >&2
  echo "Create or switch to a feature branch, then retry." >&2
  [ -n "$degraded" ] && echo "(REDUCED: jq is missing, so this ran on the built-in branch list.)" >&2
  exit 2
}

# A commit message is not a command. Matching the raw string made
# `git commit -m "push main fix"` read as a push to main — a false intercept, and
# a gate that fires on legitimate work is how gates get switched off. Strip
# quoted segments, then decide from the actual git subcommand.
scan=$(printf '%s' "$cmd" | sed -E 's/"[^"]*"/ /g' | sed -E "s/'[^']*'/ /g")

git_subcommand() {  # $1 = one shell segment
  local seen=0 skip=0 t
  for t in $1; do
    if [ "$skip" -eq 1 ]; then skip=0; continue; fi
    if [ "$seen" -eq 0 ]; then [ "$t" = "git" ] && seen=1; continue; fi
    case "$t" in
      -C|-c|--git-dir|--work-tree|--namespace) skip=1 ;;
      -*) ;;
      *) printf '%s' "$t"; return 0 ;;
    esac
  done
}

# Arguments of `git push` within one segment: everything after the `push` token,
# minus flags, minus the remote. Counting from the start of the line instead broke
# on wrappers — `timeout 90 git push origin main` dropped `origin` from the wrong
# end and examined the wrong token.
push_targets() {  # $1 = one shell segment
  printf '%s' "$1" | tr ' ' '\n' | awk '
    seen && $0 !~ /^-/ && $0 != "" { if (++n > 1) print }
    $0 == "push" { seen = 1 }'
}

current=$(git -C "$proj" rev-parse --abbrev-ref HEAD 2>/dev/null || true)

# EVERY shell segment is judged on its own. Deciding from the first git invocation
# in the whole string failed in both directions, and both were observed live:
#   * it HID a real push — `git remote set-url … && git push origin master` parsed
#     as `remote`, the push checks never ran, and the push landed;
#   * it INVENTED one — a foreign token from a later segment was read as a push
#     target, so `git push origin feature/x && ls release/notes` was blocked.
# Wildcards make the second worse: the wider the pattern, the more stray tokens
# fall under it. Quote stripping stays upstream of this, so a commit message that
# happens to contain "push main" is still not a push.
segments=$(printf '%s' "$scan" | sed -e 's/&&/\n/g' -e 's/||/\n/g' | tr ';|' '\n\n')

while IFS= read -r seg; do
  [ -z "$seg" ] && continue
  sub=$(git_subcommand "$seg")
  [ -z "$sub" ] && continue

  # 1. History-modifying commands while ON a protected branch.
  if [ -n "$current" ] && is_protected "$current"; then
    if printf ' %s ' "commit merge rebase cherry-pick revert" | grep -q " $sub " ||
       { [ "$sub" = "reset" ] && printf '%s' "$seg" | grep -q -- '--hard'; }; then
      block "current branch '$current' is protected — refusing to modify it directly"
    fi
  fi

  # 2. git push targeting a protected branch (refspecs, deletes, --force).
  if [ "$sub" = "push" ]; then
    # blockAllPush: any push is a human decision. Undoing a push on a shared
    # branch costs a force-push and other people's time — the asymmetry, not the
    # branch name, is the reason this option exists.
    [ -n "$block_all_push" ] && warn_push 'blockAllPush is set — pushing is a human action; ask the user to push'

    # Candidate destination refs: bare args and the dst side of src:dst refspecs.
    while IFS= read -r tok; do
      [ -z "$tok" ] && continue
      dst="${tok##*:}"                      # refspec dst (or the token itself)
      dst="${dst#+}"
      dst="${dst#refs/heads/}"
      if [ -n "$dst" ] && is_protected "$dst"; then
        warn_push "push targets protected branch '$dst'"
      fi
      # 'git push origin :branch' / '--delete branch' — dst is empty, src is the victim
      if [ "${tok#:}" != "$tok" ] || printf '%s' "$seg" | grep -q -- '--delete'; then
        src="${tok%%:*}"; src="${src#:}"
        [ -n "$src" ] && is_protected "$src" && warn_push "push would delete protected branch '$src'"
      fi
    done < <(push_targets "$seg")

    # Bare 'git push [--force]' pushes the current branch.
    if [ -n "$current" ] && is_protected "$current"; then
      warn_push "push from protected branch '$current'"
    fi
  fi

  # 3. Deleting a protected branch locally.
  if [ "$sub" = "branch" ] && printf '%s' "$seg" | grep -Eq '(^| )(-D|-d|--delete)( |$)'; then
    while IFS= read -r tok; do
      [ -z "$tok" ] && continue
      is_protected "$tok" && block "deleting protected branch '$tok'"
    done < <(printf '%s' "$seg" | tr ' ' '\n' | grep -vE '^-|^$|^git$|^branch$')
  fi
done <<< "$segments"

exit 0
