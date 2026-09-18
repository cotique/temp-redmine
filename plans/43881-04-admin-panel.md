# #43881 — Step 4: Admin cross-user management panel

Part of [Personal Access Tokens](43881-personal-access-tokens.md). Requires Steps
[1](43881-01-data-model-and-setting.md), [2](43881-02-authentication-and-authorization.md), and
[3](43881-03-self-service-ui.md) to be done first. 

---

```
Repo: this Redmine checkout. Prerequisite: Steps 1-3 are done. Verify the PersonalAccessToken model, auth wiring, and My Account self-service pages all exist before starting.

Goal: let an admin view and revoke ANY user's Personal Access Tokens from Administration, mirroring the existing RolesController/GroupsController admin CRUD pattern exactly.

1. Read `app/controllers/roles_controller.rb`, `app/controllers/groups_controller.rb`, and `config/routes.rb`'s `resources :roles do ... end` block in full first — `RolesController` is the pattern to mirror for the controller/menu/route shape, but NOT for pagination (see below); `GroupsController` is the pagination pattern to mirror instead.

2. Add `app/controllers/personal_access_tokens_controller.rb` (admin-only):
   - `layout 'admin'`, `self.main_menu = false`, `before_action :require_admin` (check RolesController for the exact before_action names/order it uses and match them).
   - `def index` — lists all `PersonalAccessToken.includes(:user)`, ordered sensibly (e.g. by user, then expiration). This list is unbounded (every token from every user in the instance), unlike Step 3's per-user list, so it MUST be paginated — mirror `GroupsController#index` exactly: `per_page_option` for the page size and `Paginator.new(total_count, per_page_option, params['page'])` for the pager, then `.limit(...).offset(...)` on the scope. Do not leave it unpaginated, and do not invent a different pagination approach. Default page size comes from `Setting.per_page_options_array.first`, which is **25** in this repo's `config/settings.yml` (`per_page_options` default `'25,50,100'`) — do not hardcode `25` anywhere, read it through the existing `per_page_option` helper so it stays in sync with that setting.
   - `def destroy` — admin revokes any token by id, no ownership scoping needed here (unlike Step 3's user-scoped version) since this is an admin action; redirect back to index with a notice.
   - Do NOT add create/edit actions here — admins revoke, they don't create tokens on a user's behalf. If you think they should be able to, stop and ask instead of adding it.

3. Add routes in `config/routes.rb` near `resources :roles do ... end`, using `resources :personal_access_tokens, only: [:index, :destroy]`.

4. Add `app/views/personal_access_tokens/index.html.erb` mirroring the structure of `app/views/roles/index.html.erb` (or groups', whichever is a closer structural match — check both) — table of all tokens across all users: user login/name (linked to that user's admin page), token name, scopes, expires_on, last_used_on, a revoke action per row.

5. Register the new admin page in the admin menu: add one `menu.push :personal_access_tokens, {:controller => 'personal_access_tokens'}, :caption => ..., :icon => ..., :html => {:class => 'icon icon-...'}` line inside the existing `MenuManager.map :admin_menu do |menu|` block in `lib/redmine/preparation.rb` (around where `:roles` and `:users` are registered) — follow the EXACT same hash structure as the surrounding entries. Pick an existing icon name already used elsewhere in that block if there isn't an obviously better one (check `public/` or existing icon references — do not invent a new icon asset).

6. Add English locale strings for the caption and any labels used in the view to `config/locales/en.yml` — e.g. `label_personal_access_token_plural`.

Verify — UI verification MUST be done with Playwright, not by reading code and not by manually clicking through a browser yourself. This repo already has a standalone Playwright harness at `playwright/` (see `playwright/README.md`) with `playwright.config.ts` pointed at `http://localhost:3000` and a `loginAsAdmin(page)` helper in `playwright/tests/utils.ts` whose `global-setup.ts` pins the dev DB's admin password via `docker compose exec ... rails runner` before any spec runs — do not change that mechanism:
- Start the dev environment: `docker compose up -d` from the repo root.
- This step needs a second, non-admin user to test both "tokens from multiple users are listed" and "a non-admin is denied access." Add a `loginAsNonAdminUser(page)` helper to `playwright/tests/utils.ts`, following the exact same pattern as `global-setup.ts` — i.e. ensure a known non-admin test user exists and has a known password via `docker compose exec ... rails runner` (create it if `User.find_by_login` returns nil, otherwise reuse it and reset its password the same deterministic way `global-setup.ts` does for admin), then log in through the UI with those credentials. Do not hardcode assumptions about a pre-existing non-admin user in the dev DB.
- Add a new spec file `playwright/tests/personal-access-tokens-admin.spec.ts` that:
  - Logs in as admin, creates a token or two for the admin account and (via the non-admin login helper, in a second browser context/page) creates a token for the non-admin user, via the existing My Account UI from Step 3.
  - Logs in as admin, navigates to Administration, asserts the new "Personal access tokens" entry is present and navigates to it.
  - Asserts the admin listing shows tokens belonging to both users.
  - Creates enough tokens across the two users (more than one page's worth — pass a small `?per_page=<n>` from `Setting.per_page_options_array`, don't create dozens of real tokens just to prove pagination) to force a second page, and asserts the pager control appears and actually navigates to page 2 with different rows than page 1.
  - Revokes one token from the admin panel and asserts it disappears from the admin list.
  - Logs in as the non-admin user and navigates directly to the admin URL (e.g. `/personal_access_tokens`), asserting the response is a denial (403 page or redirect away from the admin page — assert on whatever the app actually does for a non-admin hitting an admin-only page, don't assume).
- From `playwright/`: `npx playwright test`. All specs (including the ones from Step 3) must still pass — paste the actual terminal output in your final report.
- No separate API-level revocation check is needed here anymore: Step 2.2 already added a permanent Minitest test proving a destroyed `PersonalAccessToken` stops authenticating (`test_api_should_deny_auth_using_revoked_personal_access_token_as_parameter` in `test/integration/api_test/authentication_test.rb`), and this step's own Playwright spec already proves the admin panel's revoke action removes the record. Don't re-add an ad hoc curl/API spot-check for this. (This bullet replaces an earlier version of this plan that predated Step 2.2 and asked for exactly that redundant check.)
- Run `bundle exec rubocop app/controllers/personal_access_tokens_controller.rb lib/redmine/preparation.rb`.

Constraints:
- Do not add create/edit for admins, only index/destroy, as specified above.
- Do not commit. Leave changes in the working tree for review.
```
