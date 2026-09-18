# #43881 — Step 2: Wire into authentication + authorization

Part of [Personal Access Tokens](43881-personal-access-tokens.md). Requires
[Step 1](43881-01-data-model-and-setting.md) to be done first. 

---

```
Repo: this Redmine checkout. Prerequisite: Step 1 (PersonalAccessToken model + migration) is already done and merged into the working tree — verify `app/models/personal_access_token.rb` and the `personal_access_tokens` table exist before starting; if they don't, stop and report instead of recreating them.

Goal: make Personal Access Tokens actually authenticate API requests, without touching any UI.

1. In `app/controllers/application_controller.rb`, inside `find_current_user` (read the method fully first — it currently checks, in order: session, autologin, atom key, then for API requests: `api_key_from_request` → legacy `User.find_by_api_key`, then Doorkeeper OAuth, then HTTP Basic). Add a PAT check that runs BEFORE the legacy `User.find_by_api_key` fallback, using the exact same `key = api_key_from_request` value already extracted (a PAT and a legacy API key arrive via the same transports — header, `key=` param, HTTP Basic username — so do not add a second key-extraction path):
   - If `key` is present, first try `PersonalAccessToken.find_by_value(key)`.
   - If found and NOT expired: set `user = token.user`, call `token.touch_last_used!`, and if `token.scope_list` is present, set `user.oauth_scope = token.scope_list` (this is the exact same attribute the Doorkeeper OAuth branch already sets a few lines later — reuse it, do not add a new attribute on User).
   - If found but expired: treat as no match (fall through to legacy API key / other checks) — do not raise or render an error directly here, just don't authenticate with it.
   - Only if no PAT matched, fall through to the existing `User.find_by_api_key(key)` legacy path exactly as it is today.
   - Do not change the Doorkeeper OAuth branch or the HTTP Basic branch at all.

2. Confirm (read-only check, no code change needed) that `User#allowed_to?` in `app/models/user.rb` already passes `@oauth_scope` into `role.allowed_to?(action, @oauth_scope)` for both the project and global branches — it does. This means once `user.oauth_scope` is set from a PAT's scope_list, authorization is already correctly restricted with zero further changes. If you find this is NOT already wired for some code path, report it — do not add new authorization logic without asking.

3. Add `PersonalAccessToken.destroy_expired` or equivalent cleanup is OUT OF SCOPE for this step — do not add a rake task or scheduled job.

Verify:
- Write a quick manual check (Rails console or a curl-based smoke test against the running dev server) proving:
  a) A valid, unexpired PAT authenticates successfully against a real API endpoint (e.g. `GET /issues.json` with the PAT as the `key` param or as HTTP Basic username) and returns 200.
  b) An expired PAT does NOT authenticate (falls through, and since it's not a valid legacy key either, the request is treated as unauthenticated — 401, or the anonymous user's permissions apply, matching how an unrecognized key already behaves today).
  c) A PAT created with `scopes: "view_issues"` gets a 200 on an endpoint gated by `:view_issues` but is denied (403) on an endpoint gated by a permission NOT in its scope list (e.g. `:edit_issues` on an update request) — this proves the scope intersection is actually taking effect, not just being set and ignored.
  d) Existing legacy API key auth (a plain `user.api_key`) still works unchanged.
  e) A revoked PAT (i.e. its row `.destroy`ed) immediately stops authenticating — `find_by_value` returns nil for it and the request is treated as unauthenticated, same as (b). This is the whole revocation guarantee for this design: there is no separate "blacklist" of revoked tokens to check against — hard-deleting the row IS the revocation, and every authentication attempt does a live lookup (no caching layer sits in front of it, see the index doc's trade-offs section), so there's nothing else that needs checking. Prove this explicitly rather than assuming it from (b).
- Run the existing test suite's authentication-related tests: `ruby test/functional/application_controller_test.rb` and `ruby test/unit/user_test.rb` (adjust paths if these aren't the exact files — grep test/ for `find_current_user` and `try_to_login` first to find the real test files) and confirm nothing that was passing before is now broken.
- Run `bundle exec rubocop app/controllers/application_controller.rb`.

Constraints:
- Do not touch routes.rb, MyController, any admin controller, or any view — those are later steps.
- Do not change the order or behavior of any existing branch in find_current_user other than inserting the new PAT check where specified.
- Do not commit. Leave changes in the working tree for review.
```
