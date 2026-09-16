#!/usr/bin/env bash
# PreToolUse (Bash|Edit|Write) + UserPromptSubmit hook — keep credentials out of
# files, commands, and the transcript. Bash twin of secret-guard.ps1.
#
# Two jobs, because the two cases have different remedies:
#
#   PreToolUse       -> BLOCK. A secret about to be written into a file or a
#                       command is preventable, so prevent it.
#   UserPromptSubmit -> WARN only. Once a human has pasted a password into the
#                       chat it is already on disk; blocking the turn would not
#                       unsay it. The value is telling you to rotate it now.
#
# Registering this hook is the opt-in: it runs with sane defaults even without a
# config section, because the cost of missing a leaked key is asymmetric. Tune
# via .claude/discipline.json → "secrets": { "extraPatterns": [...],
# "ignorePatterns": [...], "enabled": false }.
#
# False positives are the real risk — a gate that fires on placeholders teaches
# people to ignore gates — so placeholders and env-var references are ignored.
# deps: jq

set -u
. "$(dirname "$0")/_events.sh"
payload=$(cat)

# REDUCED mode. The built-in detectors are literals in this script, so they work
# with no parser at all — only the payload read and the user-configured lists need
# jq. Losing the custom lists is worth far less than losing the gate: without this
# branch a literal secret went through in silence.
degraded=""
disc_have_jq || degraded=1

if [ -z "$degraded" ]; then
  DISC_SESSION_ID=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null | tr -d '\r')
else
  DISC_SESSION_ID=$(printf '%s' "$payload" | disc_field_crude session_id)
fi
export DISC_SESSION_ID

config=$(disc_config_path)
# `// "true"` would be wrong here: jq's alternative operator treats `false` the
# same as absent, so "enabled": false read as enabled. Compare explicitly.
if [ -z "$degraded" ] && [ -f "$config" ] && [ "$(jq -r 'if .secrets.enabled == false then "off" else "on" end' "$config" 2>/dev/null | tr -d '\r')" = "off" ]; then
  exit 0
fi
# In reduced mode `"enabled": false` cannot be read through a parser, and a gate
# the owner switched off must stay off — so check for it crudely rather than
# overriding an explicit decision.
if [ -n "$degraded" ] && [ -f "$config" ] &&
   grep -q '"enabled"[[:space:]]*:[[:space:]]*false' "$config" 2>/dev/null; then
  exit 0
fi

if [ -z "$degraded" ]; then
  prompt=$(printf '%s' "$payload" | jq -r '.prompt // empty' 2>/dev/null | tr -d '\r')
else
  prompt=$(printf '%s' "$payload" | disc_field_crude prompt)
fi
if [ -n "$prompt" ]; then
  is_prompt=1
  text="$prompt"
else
  is_prompt=0
  if [ -z "$degraded" ]; then
    text=$(printf '%s' "$payload" | jq -r '[.tool_input.command, .tool_input.content, .tool_input.new_string, .tool_input.file_text] | map(select(. != null)) | join("\n")' 2>/dev/null | tr -d '\r')
  else
    text=$(for fld in command content new_string file_text; do
             printf '%s' "$payload" | disc_field_crude "$fld"
           done)
  fi
fi
[ -z "$text" ] && exit 0

ignore_file=$(mktemp); trap 'rm -f "$ignore_file"' EXIT
cat > "$ignore_file" <<'IGN'
(x{3,}|y{3,}|z{3,}|\*{3,}|\.{3,})
(changeme|example|dummy|placeholder|redacted|your[-_]|sample|fake|test[-_]?key|<[^>]{3,}>)
\$\{?[A-Za-z_][A-Za-z0-9_]*\}?
%[A-Za-z_][A-Za-z0-9_]*%
process\.env\.
os\.environ
IGN
# Reduced mode keeps only the built-in ignore list above, so false positives stay
# controlled even when the custom lists cannot be read.
if [ -f "$config" ] && [ -z "$degraded" ]; then
  disc_jq_lines '.secrets.ignorePatterns[]?' "$config" >> "$ignore_file"
fi

is_placeholder() {  # $1 = matched sample
  while IFS= read -r ig; do
    [ -z "$ig" ] && continue
    printf '%s' "$1" | grep -Eqi -e "$ig" && return 0
  done < "$ignore_file"
  return 1
}

# A value that is an expression is code, not a credential. Measured on a real
# session: an async C# signature whose cancellation parameter carries a
# `default(...)` initialiser, and a property assigned from a getter call, were both
# read as assigned credentials — which blocked every write to that file until the
# code was rewritten. A call expression is long, so the length guard does not help.
looks_like_expression() {
  printf '%s' "$1" | grep -Eq '[A-Za-z0-9_)][(<]|[<>]'
}

hits=""
check() {  # $1 = label, $2 = pattern
  while IFS= read -r sample; do
    [ -z "$sample" ] && continue
    looks_like_expression "$sample" && continue
    is_placeholder "$sample" || { case "$hits" in *"$1"*) ;; *) hits="${hits}${1}, ";; esac; return 0; }
  done < <(printf '%s' "$text" | grep -Eoi -e "$2" 2>/dev/null)
}

check 'private key block'       '-----BEGIN [A-Z ]*PRIVATE KEY-----'
check 'AWS access key id'       'AKIA[0-9A-Z]{16}'
check 'GitHub token'            'gh[pousr]_[A-Za-z0-9]{30,}'
check 'Slack token'             'xox[baprs]-[A-Za-z0-9-]{10,}'
check 'Google API key'          'AIza[0-9A-Za-z_-]{35}'
check 'JWT'                     'eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}'
check 'Azure storage key'       'AccountKey[[:space:]]*=[[:space:]]*[A-Za-z0-9+/]{40,}={0,2}'
check 'credential in a URL'     '[a-z][a-z0-9+.-]*://[^:/[:space:]@]+:[^@/[:space:]]{6,}@'
# \b for parity with the PowerShell twin, which has always had it here. Without
# boundaries the keyword matched inside a longer identifier, so a camelCase property
# name containing one of these words read as an assignment of a credential.
check 'assigned password/token' '\b(password|passwd|pwd|secret|api[-_]?key|apikey|access[-_]?token|auth[-_]?token|client[-_]?secret)\b[[:space:]]*[:=][[:space:]]*"?[^[:space:]"'"'"'`,;<>${}%]{8,}'

# Credentials pasted in prose — this is how a human leaks one in chat, and every
# code-shaped pattern above misses it. The value must look like a secret (contains a
# digit, or is long) or a sentence like "the token is invalid" fires.
#
# \b matters, and its absence was the other half of the same defect: without
# boundaries the keyword matched INSIDE a longer identifier, so any camelCase name
# ending in one of these words read as an assignment. The PowerShell twin already
# had the boundaries; this one did not, and the two are documented as identical.
narrative='\b(password|passwd|pwd|secret|api[-_ ]?key|apikey|token|credential)\b[[:space:]]*(is|are|=|:)[[:space:]]*"?[^[:space:]"'"'"'`,;]{8,}'
while IFS= read -r sample; do
  [ -z "$sample" ] && continue
  val=$(printf '%s' "$sample" | sed -E 's/.*(is|are|=|:)[[:space:]]*"?//')
  [ -z "$val" ] && continue
  looks_like_expression "$val" && continue
  if ! printf '%s' "$val" | grep -q '[0-9]' && [ ${#val} -lt 16 ]; then continue; fi
  is_placeholder "$val" || { case "$hits" in *'credential in prose'*) ;; *) hits="${hits}credential in prose, ";; esac; }
done < <(printf '%s' "$text" | grep -Eoi -e "$narrative" 2>/dev/null)

if [ -f "$config" ] && [ -z "$degraded" ]; then
  n=0
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    n=$((n + 1))
    check "project pattern $n" "$p"
  done < <(disc_jq_lines '.secrets.extraPatterns[]?' "$config")
fi

[ -z "$hits" ] && exit 0
what=${hits%, }

if [ "$is_prompt" -eq 1 ]; then
  disc_log secret-guard warn fail "$what"
  echo "[secret-guard] This message appears to contain a credential ($what)."
  echo "  It is now in the transcript on disk. Treat it as compromised and rotate it."
  echo "  Do not echo it into a file, a command, or a commit. Refer to the secret store"
  echo "  or an environment variable name instead."
  [ -n "$degraded" ] && echo "  (REDUCED: jq is missing, so only the built-in detectors ran.)"
  exit 0
fi

if [ "$(disc_mode)" = "shadow" ]; then
  disc_log secret-guard would-block fail "$what"
  echo "[secret-guard] SHADOW (not enforced): credential material in tool input ($what)" >&2
  exit 0
fi
disc_log secret-guard block fail "$what"
{
  echo "[secret-guard] BLOCKED: this would write credential material ($what)."
  echo "Use the secret store or an environment variable reference instead of the literal value."
  echo "If the value is a placeholder the pattern misread, add it to secrets.ignorePatterns."
  [ -n "$degraded" ] && echo "(REDUCED: jq is missing, so only the built-in detectors ran.)"
} >&2
exit 2
