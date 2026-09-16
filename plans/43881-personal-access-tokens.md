# #43881 — Personal Access Tokens (hybrid self-service + admin model)

Source: [redmine.org/issues/43881](https://www.redmine.org/issues/43881) ("Strengthen API
Authentication", proposal 1) only. This is an independent, from-scratch design based on that
proposal and this codebase's own existing conventions — nothing from issue #44430 (the separate
tracking issue the proposal was later split into, including its attached patch) was used as
input.

Produced by `/orchestrate` on branch `test-43881`.

## Design summary

Add a `PersonalAccessToken` model/table (SHA256-hashed value, mandatory expiration, optional
space-separated permission scopes, last-used tracking) as a new, additive authentication method.
It plugs into the *existing* auth chain in `ApplicationController#find_current_user` as one more
branch — checked before the legacy API key — and reuses the *existing* scope-intersection
mechanism (`User#oauth_scope` + `Role#allowed_to?(action, scope)`) that Doorkeeper OAuth already
uses, so no new authorization architecture is needed. Self-service management lives in
`MyController` (mirroring its existing `show_api_key`/`reset_api_key`, sudo-mode-gated), and
cross-user admin oversight is a new resourceful admin controller mirroring
`RolesController`/`GroupsController`, registered in the existing `admin_menu`.

**Verdict: SAFE TO IMPLEMENT** — every piece (migration, model, `Role#allowed_to?` scope
intersection, `require_sudo_mode`, admin resourceful CRUD, `admin_menu` registration,
`Setting`/`config/settings.yml`) is an existing Redmine pattern. No new architecture required.

## Known trade-offs (accepted, not addressed by this design)

- **No caching/throttling on the last-used write.** `token.touch_last_used!` (Step 2) writes to
  `personal_access_tokens` on every authenticated API request, unconditionally. This was a
  deliberate choice, not an oversight: this codebase has no hot-path caching layer to plug into in
  the first place — `Rails.cache` is never called anywhere in `app/` or `lib/`, and the closest
  existing analogue, `record_project_usage`'s `UserPreference` write on every project page view,
  has exactly the same unthrottled shape. Matching that existing (uncached) pattern was judged more
  consistent than introducing the first caching layer in the codebase as a side effect of this
  feature. If PAT write volume becomes a real problem, that's a separate, general infrastructure
  change — not something to solve inside this feature.

- **No cleanup of expired tokens.** An expired `PersonalAccessToken` row is never deleted — it just
  stops authenticating (Step 2's `expired?` check) and sits in the table forever unless a human
  revokes it manually (My Account or the admin panel). Table growth is unbounded over the life of
  the instance. This is a deliberate scope cut (Step 2 explicitly rules out adding a rake task or
  scheduled job), and it's actually consistent with, not a regression from, the existing codebase:
  the generic `Token` model already has `Token.destroy_expired` ([app/models/token.rb:75](../app/models/token.rb:75))
  covering autologin/api/feeds/recovery/register/session/2FA-backup-code tokens — verified, it is
  called **only from `test/unit/token_test.rb`**, nowhere in the actual app (no rake task, no
  scheduled job, no controller call). So every existing token type in this codebase already
  accumulates expired rows forever in a real deployment unless an operator wires up their own
  external cron for it. PAT not doing cleanup either isn't a new gap — it's the status quo.
  **Because of this, both token lists (Step 3's per-user list and Step 4's admin list) are
  paginated from the start**, rather than treating the per-user list as small/bounded the way
  `RolesController`'s unpaginated list is — an account's own token list is unbounded in practice
  over its lifetime precisely because nothing ever prunes it.

## Steps

Each step is a self-contained, ready-to-paste prompt for a worker Claude session with no prior
context. Run them in order — each one's prerequisite check assumes the previous step landed.

1. [Step 1 — Data model + Setting](43881-01-data-model-and-setting.md)
2. [Step 2 — Wire into authentication + authorization](43881-02-authentication-and-authorization.md)
3. [Step 3 — Self-service UI in My Account](43881-03-self-service-ui.md)
4. [Step 4 — Admin cross-user management panel](43881-04-admin-panel.md)

## Constraints that apply to every step

- No new gems.
- No commits — each worker leaves changes in the working tree for review.
- No new architecture/abstractions beyond what's named in each prompt — if the codebase doesn't
  actually have what a prompt assumes, the worker should stop and report rather than improvise.
- Any UI verification is done with the Playwright harness at [`playwright/`](../playwright/)
  (config, `README.md`, and a `loginAsAdmin` helper already exist there and are verified working)
  — not by reading code, and not by a human/worker manually clicking through a browser. Steps 3
  and 4 add real spec files to `playwright/tests/` as part of their own verification.
