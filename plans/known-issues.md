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
