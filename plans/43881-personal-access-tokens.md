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

- **No caching on the admin-allowed-scopes lookup (Step 5).** `PersonalAccessToken.allowed_permissions`
  / `allowed_permission_names` read `Setting.personal_access_token_allowed_scopes` fresh on every
  call — at token-creation time in `MyController`, at request time in
  `ApplicationController#find_user_by_pat_or_api_key`, and when rendering the scope picker and the
  admin checkbox UI. This is the same "no hot-path caching layer exists in this codebase" reasoning
  as the last-used-write trade-off above, applied to a second read that now also happens on every
  authenticated API request, not just on writes. `Setting`'s own built-in per-request cache
  (`@cached_settings`, invalidated by `check_cache` in `ApplicationController#user_setup`) already
  covers the ordinary case of a setting not changing mid-request; nothing beyond that is added.

- **No auto-revocation or notification when a token's scopes are all disabled (Step 5).** If an
  admin removes every permission a given token was scoped to from the allow-list, that token is
  denied outright on its next authentication attempt (see Step 5's own plan for the exact
  mechanism), but it is not revoked and nobody (admin or token owner) is notified — the row keeps
  existing, inert, until a human revokes it manually or it expires. This is a deliberate scope cut,
  not an oversight: proactive revocation and/or a notification are both plausible future work, but
  neither is needed for the security property this step is actually after (an already-disabled
  permission can no longer be exercised via any PAT on its very next request), and adding either
  now would be new behavior beyond what was asked for.

- **The Step 5 allow-list fails closed by default.** `Setting.personal_access_token_allowed_scopes`
  defaults to empty, which means "no permission is currently allowed as a PAT scope" — not
  "unrestricted." Combined with Step 5's own model-level "at least one scope required" validation
  (`validates_presence_of :name, :expires_on, :scopes`, no exceptions), no Personal Access Token can
  be created at all until an instance admin visits Settings → API and explicitly enables at least
  one permission. Step 3's original "blank scopes = unrestricted/full access" design is fully
  superseded by this — there is no grandfathering, since Steps 1 through 5 ship together as a single
  delivery with no real window where a blank-scope token could have been created and left in use.
  See Step 5's own plan for the full reasoning.

## Steps

Each step is a self-contained, ready-to-paste prompt for a worker Claude session with no prior
context. Run them in order — each one's prerequisite check assumes the previous step landed.

1. [Step 1 — Data model + Setting](43881-01-data-model-and-setting.md)
2. [Step 2 — Wire into authentication + authorization](43881-02-authentication-and-authorization.md)
3. [Step 2.1 — Extend PAT support to HTTP Basic auth](43881-02.1-http-basic-auth.md) — a fix-up
   found during Step 2's own verification, not part of the original design: Step 2's plan
   contradicted itself (expected PAT-via-HTTP-Basic to work, but also hard-constrained "don't touch
   the HTTP Basic branch"). The worker correctly followed the explicit constraint and flagged the
   resulting gap instead of guessing. This step closes it.
4. [Step 2.2 — Minitest coverage for PAT auth, retire the Playwright API spec](43881-02.2-minitest-auth-coverage.md) —
   `playwright/tests/personal-access-tokens-api.spec.ts` was a stand-in because no UI existed yet
   to verify with Playwright; the real, idiomatic home for this coverage is
   `test/integration/api_test/authentication_test.rb`, which already tests every other auth
   transport in exactly this style. Once real Minitest coverage exists there, the Playwright API
   spec becomes pure duplication and gets deleted, not kept alongside it.
5. [Step 2.3 — Stop logging PAT/API key values in plaintext](43881-02.3-filter-credentials-from-logs.md) —
   a real credential leak observed directly in this session's own dev server log (not
   hypothesized): the raw PAT value appears in plaintext in the `Parameters:` log line whenever
   sent as `?key=`, because `config.filter_parameters` only filters `:password`. Narrow fix, not a
   logging-infrastructure change.
6. [Step 3 — Self-service UI in My Account](43881-03-self-service-ui.md)
7. [Step 4 — Admin cross-user management panel](43881-04-admin-panel.md)
8. [Step 5 — Admin-managed allow-list for PAT scopes](43881-05-scopes-management.md) — Step 3's
   scope picker lets a user request any non-public permission as a token scope; this step adds an
   admin-editable allow-list (`Setting.personal_access_token_allowed_scopes`, empty/nothing-allowed
   by default) that narrows the universe Step 3 draws from, enforced both at token-creation time
   and, critically, at every authenticated request (not just creation), so disabling a permission
   instance-wide takes effect on an already-issued token's very next request — by denying that
   token outright, not by assigning it an empty scope.

## Constraints that apply to every step

- No new gems.
- No commits — each worker leaves changes in the working tree for review.
- No new architecture/abstractions beyond what's named in each prompt — if the codebase doesn't
  actually have what a prompt assumes, the worker should stop and report rather than improvise.
- Any UI verification is done with the Playwright harness at [`playwright/`](../playwright/)
  (config, `README.md`, and a `loginAsAdmin` helper already exist there and are verified working)
  — not by reading code, and not by a human/worker manually clicking through a browser. Steps 3
  and 4 add real spec files to `playwright/tests/` as part of their own verification.
