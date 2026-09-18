# PreToolUse hook (matcher: Bash) — blocks destructive git operations that would
# modify a protected branch. PowerShell twin of hooks/bash/block-protected-branch.sh.
#
# stdin:  Claude Code hook payload JSON ({ tool_input: { command: "..." } })
# exit 0: allow    exit 2: block (stderr is fed back to Claude)

$ErrorActionPreference = 'Continue'
. "$PSScriptRoot\_events.ps1"

try { $payload = [Console]::In.ReadToEnd() | ConvertFrom-Json } catch { exit 0 }
if ($payload.session_id) { $env:DISC_SESSION_ID = $payload.session_id }
$cmd = $payload.tool_input.command
if (-not $cmd -or $cmd -notmatch 'git') { exit 0 }

$proj = if ($env:CLAUDE_PROJECT_DIR) { $env:CLAUDE_PROJECT_DIR } else { '.' }
$configPath = Join-Path $proj '.claude\discipline.json'
$branches = @('main', 'master', 'develop', 'release/*')
$blockAllPush = $false
if (Test-Path $configPath) {
    try {
        $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
        if ($cfg.protectedBranches) { $branches = @($cfg.protectedBranches) }
        if ($cfg.blockAllPush) { $blockAllPush = $true }
    } catch {}
}

function Test-Protected([string]$branch) {
    foreach ($pat in $branches) { if ($branch -like $pat) { return $true } }
    return $false
}

# Pushes are WARNED about here and REFUSED by the pre-push git hook, which git
# hands the real refs on stdin. This gate only ever sees the text of a command that
# has not run, and every defect it had was the same defect: no model of shell
# structure. Corrected once for quoting, once for separators, with $(...), bash -c,
# xargs and multi-line scripts still ahead. A false positive in an advisory layer
# costs a sentence; in a blocking layer it costs a session, and that is how gates
# get switched off.
#
# exit 2 is kept for exactly what pre-push cannot see: a commit landing on a
# protected branch, and a local branch deletion. Neither reaches a remote, so git
# never offers a hook with authoritative data.
function Warn-Push([string]$reason) {
    Write-DiscEvent -Asset 'block-protected-branch' -Event 'warn-push' -Verdict 'fail' -Detail $reason
    [Console]::Error.WriteLine("[block-protected-branch] $reason")
    [Console]::Error.WriteLine('The pre-push hook will refuse this; it reads the real refs from git.')
    [Console]::Error.WriteLine('If it is not installed in this repo, nothing else will stop it — run apply.')
    exit 0
}

function Block([string]$reason) {
    if ((Get-DiscMode) -eq 'shadow') {
        # Shadow: record what would have been stopped, let it through. One window
        # of this proves the gate's value before it can annoy anyone.
        Write-DiscEvent -Asset 'block-protected-branch' -Event 'would-block' -Verdict 'fail' -Detail $reason
        [Console]::Error.WriteLine("[block-protected-branch] SHADOW (not enforced): $reason")
        exit 0
    }
    Write-DiscEvent -Asset 'block-protected-branch' -Event 'block' -Verdict 'fail' -Detail $reason
    [Console]::Error.WriteLine("[block-protected-branch] BLOCKED: $reason")
    [Console]::Error.WriteLine('Create or switch to a feature branch, then retry.')
    exit 2
}

# A commit message is not a command. Matching the raw string made
# `git commit -m "push main fix"` read as a push to main — a false intercept, and
# a gate that fires on legitimate work is how gates get switched off. Strip
# quoted segments, then decide from the actual git subcommand rather than from
# any word that happens to appear.
$scan = ($cmd -replace '"[^"]*"', ' ') -replace "'[^']*'", ' '

function Get-GitSubcommand([string]$text) {
    $tokens = ($text -split '\s+') | Where-Object { $_ }
    $i = [Array]::IndexOf($tokens, 'git')
    if ($i -lt 0) { return $null }
    for ($j = $i + 1; $j -lt $tokens.Count; $j++) {
        $t = $tokens[$j]
        # global options that carry a value, and plain flags, precede the subcommand
        if ($t -in @('-C', '-c', '--git-dir', '--work-tree', '--namespace')) { $j++; continue }
        if ($t.StartsWith('-')) { continue }
        return $t
    }
    return $null
}
# Arguments of `git push` within one segment: everything after the `push` token,
# minus flags, minus the remote. Counting from the start of the line instead broke
# on wrappers — `timeout 90 git push origin main` dropped a token from the wrong end.
function Get-PushTargets([string]$segment) {
    $out = @(); $seen = $false; $n = 0
    foreach ($t in (($segment -split '\s+') | Where-Object { $_ })) {
        if ($seen -and $t -notmatch '^-') { $n++; if ($n -gt 1) { $out += $t } }
        if ($t -eq 'push') { $seen = $true }
    }
    return $out
}

$current = git -C $proj rev-parse --abbrev-ref HEAD 2>$null

# EVERY shell segment is judged on its own. Deciding from the first git invocation
# in the whole string failed in both directions, and both were observed live:
#   * it HID a real push — `git remote set-url … && git push origin master` parsed
#     as `remote`, the push checks never ran, and the push landed;
#   * it INVENTED one — a foreign token from a later segment was read as a push
#     target, so a push to a feature branch followed by an unrelated command was
#     blocked.
# Wildcards make the second worse: the wider the pattern, the more stray tokens
# fall under it. Quote stripping stays upstream, so a commit message that happens
# to contain "push main" is still not a push.
$segments = [regex]::Split($scan, '&&|\|\||;|\|')

foreach ($seg in $segments) {
    if (-not $seg -or -not $seg.Trim()) { continue }
    $sub = Get-GitSubcommand $seg
    if (-not $sub) { continue }

    # 1. History-modifying commands while ON a protected branch.
    if ($current -and (Test-Protected $current)) {
        if ($sub -in @('commit', 'merge', 'rebase', 'cherry-pick', 'revert') -or
            ($sub -eq 'reset' -and $seg -match '--hard')) {
            Block "current branch '$current' is protected — refusing to modify it directly"
        }
    }

    # 2. git push targeting a protected branch (refspecs, deletes, --force).
    if ($sub -eq 'push') {
        # blockAllPush: any push is a human decision. Undoing a push on a shared
        # branch costs a force-push and other people's time — the asymmetry, not
        # the branch name, is the reason this option exists.
        if ($blockAllPush) {
            Warn-Push 'blockAllPush is set — pushing is a human action; ask the user to push'
        }
        foreach ($tok in (Get-PushTargets $seg)) {
            $dst = ($tok -split ':')[-1].TrimStart('+') -replace '^refs/heads/', ''
            if ($dst -and (Test-Protected $dst)) { Warn-Push "push targets protected branch '$dst'" }
            if ($tok.StartsWith(':') -or $seg -match '--delete') {
                $src = ($tok -split ':')[0].TrimStart(':')
                if ($src -and (Test-Protected $src)) { Warn-Push "push would delete protected branch '$src'" }
            }
        }
        if ($current -and (Test-Protected $current)) { Warn-Push "push from protected branch '$current'" }
    }

    # 3. Deleting a protected branch locally.
    if ($sub -eq 'branch' -and $seg -match '(^|\s)(-D|-d|--delete)(\s|$)') {
        $tokens = ($seg -split '\s+') | Where-Object { $_ -and $_ -notmatch '^-' -and $_ -notin @('git', 'branch') }
        foreach ($tok in $tokens) {
            if (Test-Protected $tok) { Block "deleting protected branch '$tok'" }
        }
    }
}

exit 0
