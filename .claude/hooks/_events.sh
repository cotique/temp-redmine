# Shared event logging for the pack's hooks. Not a hook itself — sourced by them.
#
# Guardrails nobody measures decay into folklore. Every hook appends one line per
# firing so adoption, intercepts and cost become queries instead of transcript
# archaeology.
#
# config: .claude/discipline.json →
#   "mode": "enforce" | "shadow",     # shadow: blocking hooks log but allow
#   "events": { "enabled": true, "path": ".claude/discipline-events.jsonl" }
# Events default to ON (a log nobody enabled is a log nobody has); mode defaults
# to enforce.
#
# Usage:
#   . "$(dirname "$0")/_events.sh"
#   disc_mode                       -> echoes "enforce" | "shadow"
#   disc_log <asset> <event> <verdict> [detail] [durationMs]

disc_config_path() { echo "${CLAUDE_PROJECT_DIR:-.}/.claude/discipline.json"; }

# Read a jq expression LINE BY LINE. The Windows build of jq emits CRLF, and a
# trailing \r survives every line-wise read: `mapfile -t` and `while read` both
# keep it. Measured on Git Bash — `.dod.fileGlobs[]?` came back as `*.cs\r`
# (od -c: * . c s \r \n), so `case b.cs in *.cs<CR>)` never matched and the whole
# definition-of-done gate silently became a no-op; and with several protected
# branches configured, only the LAST one was ever enforced, because $() strips the
# final \r and nothing strips the others.
#
# Single-value reads through $() are NOT automatically safe either, which is worth
# stating because it is easy to assume they are. Measured both ways: on Git Bash
# $() does drop the \r, but on Linux it does not — command substitution strips
# trailing NEWLINES, and the carriage return sits in front of them. A config read
# returning the empty string came back as "\r", `[ -n ... ]` saw a value, and
# blockAllPush switched itself on, refusing every push. Depending on the Git Bash
# behaviour was depending on a platform quirk rather than a guarantee, so every jq
# capture in these hooks strips \r explicitly.
disc_jq_lines() { jq -r "$1" "$2" 2>/dev/null | tr -d '\r'; }

disc_have_jq() { command -v jq >/dev/null 2>&1; }

# Parser-free extraction of one string field from the hook payload, for REDUCED
# mode only. Without jq a gate has two bad options — vanish, or refuse every call
# it cannot parse — and a third better one: keep working on built-in defaults and
# say that it is doing so. This is how it reads the payload in that state.
#
# It stops at the first quote in the value, so a command containing escaped quotes
# comes back truncated. That is a real loss of coverage, which is why every caller
# labels its verdict REDUCED rather than passing it off as a full check. Erring
# toward missing rather than toward blocking is deliberate: a gate that fires on
# work it misread is how gates get switched off.
disc_field_crude() { # field name; payload on stdin
  sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
}

disc_mode() {
  local c; c=$(disc_config_path)
  local m=""
  [ -f "$c" ] && m=$(jq -r '.mode // empty' "$c" 2>/dev/null | tr -d '\r')
  case "$m" in shadow) echo shadow ;; *) echo enforce ;; esac
}

disc_json_escape() {
  # Escape for a JSON string value; keeps the log parseable when commands
  # contain quotes, backslashes or newlines.
  printf '%s' "$1" | jq -Rs '.' 2>/dev/null || printf '""'
}

disc_log() {
  local asset="$1" event="$2" verdict="$3" detail="${4:-}" duration="${5:-}"
  local c; c=$(disc_config_path)
  [ -f "$c" ] || return 0

  local enabled path
  if disc_have_jq; then
    enabled=$(jq -r 'if .events.enabled == false then "no" else "yes" end' "$c" 2>/dev/null | tr -d '\r')
    path=$(jq -r '.events.path // ".claude/discipline-events.jsonl"' "$c" 2>/dev/null | tr -d '\r')
  else
    # Reduced mode: an unreadable config used to leave path empty, which resolved
    # to the project directory itself and made every append fail with
    # "Is a directory" on stderr — noise from a gate that was otherwise working.
    # Honour an explicit off switch crudely, then fall back to the default path.
    grep -q '"enabled"[[:space:]]*:[[:space:]]*false' "$c" 2>/dev/null && return 0
    enabled=yes
    path=".claude/discipline-events.jsonl"
  fi
  [ "$enabled" = "no" ] && return 0
  [ -z "$path" ] && path=".claude/discipline-events.jsonl"
  case "$path" in /*|?:*) ;; *) path="${CLAUDE_PROJECT_DIR:-.}/$path" ;; esac

  local ts session line
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)
  session="${DISC_SESSION_ID:-}"
  line="{\"ts\":\"$ts\",\"asset\":\"$asset\",\"event\":\"$event\",\"verdict\":\"$verdict\",\"mode\":\"$(disc_mode)\""
  [ -n "$session" ] && line="$line,\"sessionId\":$(disc_json_escape "$session")"
  [ -n "$detail" ] && line="$line,\"detail\":$(disc_json_escape "$detail")"
  [ -n "$duration" ] && line="$line,\"durationMs\":$duration"
  line="$line}"

  mkdir -p "$(dirname "$path")" 2>/dev/null
  printf '%s\n' "$line" >> "$path" 2>/dev/null || true
  return 0
}
