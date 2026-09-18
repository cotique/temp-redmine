# Known issues (repo-level, not tied to any specific feature branch)

## CI `bundle-audit` job fails on known CVEs in already-pinned gems

**Status:** resolved — flagged gems bumped, `bundle exec bundle audit check --update` now reports
"No vulnerabilities found."

Originally discovered while investigating a CI failure on `test-43881` (commit `a31fda6ab`) — the
failure turned out to be unrelated to that commit's actual changes (`plans/`, `playwright/`,
`.gitignore` only). `bundle-audit` pulls the *live* ruby-advisory-db at CI run time and checks it
against whatever `Gemfile` currently resolves to (there is no committed `Gemfile.lock` in this
repo — it's gitignored — so CI resolves fresh on every run), so the job failed on any push
regardless of what that push actually changed.

**Re-confirmed by actually running the job's exact step** (`.github/workflows/linters.yml`, job
`bundle-audit`, step `bundle exec bundle audit check --update`) inside the repo's Docker dev
environment before touching anything. The findings had drifted from what was previously written
here — `css_parser` was no longer flagged at all (it already resolves to `3.1.0` via `roadie
(>= 1.4, < 4.0)`, well past whatever version tripped the original scan), and three new `sqlite3`
2.5.0 CVEs (GHSA-28hh-pr2h-2w89, GHSA-j7fr-3v8c-3qc3, GHSA-mwm8-39rw-8826, fixed at `>= 2.9.6`) had
appeared that weren't recorded in the original version of this entry. Actual findings at the time
of the fix:

- `rubyzip` 2.4.1 — CVE-2026-85396, path traversal, fixed `>= 3.4.0`
- `mail` 2.8.1 — CVE-2026-63435, fixed `>= 2.9.1`
- `actionview`/`activestorage`/`activesupport` 7.2.3 — multiple CVEs, the strictest requiring
  `>= 7.2.3.2` (activestorage, CVE-2026-66066)
- `sqlite3` 2.5.0 — 3 CVEs/GHSAs, fixed `>= 2.9.6`

**Fix applied** (`Gemfile`):
- `rails` `7.2.3` → `7.2.3.2` — same patch-only bump upstream's own `6.1-stable` branch made
  (`origin/6.1-stable`'s Gemfile pins `7.2.3.2`); stays in the 7.2.x line, no Rails major/minor
  jump.
- `mail` `~> 2.8.1` → `~> 2.9.0` — actionmailer 7.2.3.2 only requires `mail >= 2.8.0` (no upper
  bound), so this is a compatible bump; resolves to 2.9.1.
- `rubyzip` `~> 2.4.0` → `~> 3.4.0` — no 2.x release fixes this CVE, so the major bump is
  required. Checked rubyzip's 3.0.0 breaking changes (named-parameters-only for optional args,
  `Zip::File` no longer subclassing `Zip::CentralDirectory`, legacy error classes removed) against
  every `Zip::` call site in this codebase (`app/models/attachment.rb:385` `Zip::OutputStream.write_buffer`/`put_next_entry(filename)`,
  `test/unit/attachment_test.rb` `Zip::InputStream.open`/`get_next_entry`/`entry.name`) — all use
  simple positional/block forms unaffected by the 3.x changes. Resolves to 3.4.1.
- `sqlite3` `~> 2.5.0` → `~> 2.9.0` (in the `config/database.yml`-driven adapter block) — same 2.x
  line, resolves to 2.9.6. Not part of the original flagged list; found by re-running the actual
  audit rather than trusting the stale numbers above.
- `css_parser`: no Gemfile change made — already resolves to a safe version transitively, and
  isn't flagged by the current audit.

`Gemfile.lock` was regenerated locally via `bundle install` (still gitignored, not committed).

**Verification:** `bundle exec bundle audit check --update` → "No vulnerabilities found." Full
Minitest suite run afterwards (5589 runs, 25387 assertions, 23 failures, 0 errors, 44 skips) —
all 23 failures are in `test/unit/lib/redmine/unified_diff_test.rb` and are pre-existing/unrelated
to this change (see new entry below); `test/unit/attachment_test.rb` (zip archival, the code path
touched by the rubyzip bump) and `test/unit/mailer_test.rb` +
`test/unit/mailer_localisation_test.rb` (the code path touched by the mail bump) were run
individually and are 100% green (45/45 and 96/96 respectively, 0 failures/errors).

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

## Local full-suite run on this Windows checkout: 23 failures in `unified_diff_test.rb`

**Status:** known gap, not addressed, not blocking feature work. Windows-checkout artifact, not a
code defect.

Discovered while running the full Minitest suite locally to verify the `bundle-audit` gem bumps
above didn't break anything. All 23 failures are in
`test/unit/lib/redmine/unified_diff_test.rb` — every one is either a stray `\r` appearing in
actual-vs-expected diff output, or an off-by-one span offset that's explained by that same stray
`\r` shifting string lengths (e.g. `test_utf8_ja`, `test_utf8_ru`, `test_offset_range_japanese_1/4/5`,
`test_side_by_side_partials`, `test_inline_partials`). None of them touch Rails, `mail`, `rubyzip`,
or `sqlite3` — the code under test (`lib/redmine/unified_diff.rb`) has no dependency on any of the
gems bumped above.

**Root cause (confirmed, not just suspected):** this checkout has `core.autocrlf=true` (Windows
git default) and the `.diff` fixtures under `test/fixtures/diffs/` were checked out with CRLF line
terminators (confirmed with `file test/fixtures/diffs/issue-12641-ja.diff` →
"... with CRLF line terminators"). `read_diff_fixture` in the test
(`test/unit/lib/redmine/unified_diff_test.rb:484`) reads them with a plain
`File.new(path).read`, so the trailing `\r` on each line survives into the parsed diff and leaks
into the rendered output. This is the same root cause family as the already-known CRLF-corrupted
`bin/rails` shebang on this Windows checkout — git-on-Windows rewriting LF to CRLF on checkout —
just hitting a different file (test fixtures instead of the shebang line).

**Why not fixed here:** out of scope for the bundle-audit CVE work — pre-existing, checkout/OS
environment-dependent (would very likely pass as-is on a Linux/macOS clone or with
`core.autocrlf=false`/`.gitattributes` normalization), not caused by or related to any gem bump.

**If this needs addressing:** either fix the checkout (`git config core.autocrlf false` + re-clone
or `git checkout -- test/fixtures/diffs`, after confirming that doesn't fight this repo's own
`.gitattributes`/`.hgignore` conventions), or make `read_diff_fixture` binmode/`\r\n`-normalize on
read so the test is checkout-line-ending-independent like the fix already accepted upstream for
the `GitAdapterTest` gap above.
