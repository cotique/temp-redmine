# Known issues (repo-level, not tied to any specific feature branch)

## CI `bundle-audit` job fails on known CVEs in already-pinned gems

**Status:** known gap, not addressed, not blocking feature work.

Discovered while investigating a CI failure on `test-43881` (commit `a31fda6ab`) — the failure
turned out to be unrelated to that commit's actual changes (`plans/`, `playwright/`, `.gitignore`
only). Confirmed via the job logs (`.github/workflows/linters.yml`, job `bundle-audit`, step
`bundle exec bundle audit check --update`):

- **rubyzip 2.4.1** — `CVE-2026-85396`, High severity (path traversal), fixed in ≥3.4.0
- Multiple Rails 7.2.3 CVEs (actionview/activestorage/activesupport)
- `mail` 2.8.1 and `css_parser` 1.22.0 also flagged

`bundle-audit` pulls the *live* ruby-advisory-db at CI run time and checks it against whatever
`Gemfile` currently resolves to (there is no committed `Gemfile.lock` in this repo — it's
gitignored — so CI resolves fresh on every run). This means the job will fail on **any** push
right now, regardless of what that push actually changes, until the flagged gems are bumped.

**Why not fixed here:** out of scope for the #43881 (Personal Access Tokens) work — it's a
pre-existing dependency/security gate on the repo as a whole, not something introduced by or
related to that feature.

**If this needs addressing:** bump `rubyzip` to ≥3.4.0, Rails to a patched 7.2.3.x/8.x point
release, `mail` to ≥2.9.1, `css_parser` to ≥3.0.0 — or, if immediate upgrades aren't feasible, add
a `bundle-audit` ignore list for accepted-risk CVEs with a tracking ticket. Either way, that's a
separate piece of work from any feature branch.

## CI `Tests` job fails on every matrix cell: `GitAdapterTest#test_diff_path_invalid`

**Status:** known gap, not addressed, not blocking feature work. Root cause confirmed, upstream
fix already exists.

Same discovery path as the `bundle-audit` gap above: looked like "all DB tests failed" on
`test-43881`, but every matrix cell (`mysql2`/`postgresql`/`sqlite3` × ruby `3.2`/`3.3`/`3.4`) runs
the *entire* test suite regardless of DB adapter, and there is exactly one failing test in all of
them — not a database problem, just one unrelated test failing identically everywhere. Confirmed
present on a completely clean, unmodified checkout of tag `6.1.2` (branch `test-compare`, zero
changes) — pre-existing, unrelated to any feature branch.

**Root cause (confirmed by local reproduction + a matching closed upstream issue, not just a
hypothesis):** Git **2.55.0** introduced a regression (git commit `dd4bc01c0a`, already fixed on
git's own master by `32c4ed70e2`) where `git show <rev> -- <path>` prints the commit header
(commit/Author/Date/message) even when `<path>` wasn't touched by that commit — Git ≤2.54.0
printed nothing. `GitAdapter#diff` ([lib/redmine/scm/adapters/git_adapter.rb:344-363](../lib/redmine/scm/adapters/git_adapter.rb:344))
builds exactly that command form, so on a CI runner shipping git 2.55.x, the test that expects an
empty diff for a non-matching path instead sees the 6-line header. Locally reproduced against the
actual fixture repo with git 2.53.0 (this machine's version) — correctly returns empty, confirming
the version-dependence. Matches upstream Redmine issue
[#44354](https://www.redmine.org/issues/44354) exactly (same test, same failure signature),
already closed, targeted at Redmine 6.0.11.

**Why not fixed here:** pre-existing, CI-environment-dependent, unrelated to #43881.

**If this needs addressing:** Redmine's own accepted fix makes `GitAdapter#diff` post-process
`git show`/`git diff` output and return `[]` whenever the captured lines contain no actual diff
content (no `diff --git`/hunk lines), so the result is git-version-independent instead of
depending on whether the installed git prints a header for a non-matching pathspec. That fix
should be pulled from upstream rather than reinvented — check issue #44354 for the actual patch
before writing a new one.
