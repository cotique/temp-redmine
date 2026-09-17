# #43881 — Step 5: Admin-managed allow-list for PAT scopes

Part of [Personal Access Tokens](43881-personal-access-tokens.md). Requires Steps
[1](43881-01-data-model-and-setting.md), [2](43881-02-authentication-and-authorization.md), and
[3](43881-03-self-service-ui.md) to be done first (all three are implemented and committed).
Independent of [Step 4](43881-04-admin-panel.md) (admin cross-user token panel, plan-only,
not implemented) — this step does not touch `PersonalAccessTokensController` or its views at all.

Why: Step 3 already lets any user pick scopes from the *entire* non-public permission universe
(`Redmine::AccessControl.permissions.reject(&:public?)`) when creating their own token. There is
currently no way for an instance admin to say "PATs may never carry permission X, no matter what a
user picks" — e.g. to keep a particularly dangerous permission (say, one that lets a token holder
manage other users) out of the PAT surface entirely, independent of what any individual user's
roles allow. This step adds that admin-managed allow-list, narrows Step 3's scope picker to it, and
enforces it both at token-creation time and at every authenticated request (not just creation), so
that disabling a permission instance-wide takes effect immediately for already-issued tokens too.

**Fails closed by default.** The allow-list is a checkbox UI, and a blank/default Setting means
literally what an all-unchecked checkbox list means: no permission is currently allowed as a PAT
scope. Combined with this step's own "at least one scope required" validation, this means **no new
Personal Access Token can be created at all until an instance admin visits Settings → API and
explicitly enables at least one permission.** This is a deliberate product decision (overriding an
earlier draft of this plan that defaulted to "unrestricted"), not an oversight — call this out
explicitly in whatever upgrade notes this branch eventually produces, since it's a real, visible
behavior change for any instance that already adopted Step 3.

---

```
Repo: this Redmine checkout. Prerequisite: Steps 1, 2, and 3 are done and committed — the
`PersonalAccessToken` model, `find_user_by_pat_or_api_key` in `app/controllers/application_controller.rb`,
and the My Account self-service pages (`app/controllers/my_controller.rb`,
`app/views/my/new_personal_access_token.html.erb`, `app/views/my/personal_access_tokens.html.erb`)
all exist. Verify all three before starting; if any is missing, stop and report. Step 4 (admin
token panel) is plan-only and NOT a prerequisite — do not wait on it, and do not touch
`app/controllers/personal_access_tokens_controller.rb` or `app/views/personal_access_tokens/`
(neither exists yet; that's Step 4's job, not this one's).

Read these in full before writing any code, and cite what you found in your final report the way
this instruction does:

- `app/controllers/my_controller.rb` — specifically `new_personal_access_token` and
  `create_personal_access_token` (already implemented; both currently use
  `Redmine::AccessControl.permissions.reject(&:public?)` directly as the full scope universe).
- `app/models/personal_access_token.rb` — specifically `scope_list` (returns `nil` for blank
  `scopes`, meaning "unrestricted", and an array of symbols otherwise).
- `app/models/role.rb` — specifically the private `allowed_permissions(scope = nil)` method
  (~line 304): `scope = scope.sort if scope.present?` then
  `scope.present? ? unscoped & scope : unscoped`. **Read this and do not copy its `[].present?`
  behavior into this step's own logic.** In Ruby/Rails, `[].present?` is `false` (an empty array is
  `blank?`), so `Role#allowed_permissions` treats a scope of `[]` the *same* as `scope = nil` and
  returns the FULL permission list — i.e. `user.oauth_scope = []` would silently grant full access,
  the opposite of "deny everything". Do **not** work around this by inventing a sentinel/decoy
  permission name to smuggle a non-empty-but-unsatisfiable array through this method (an earlier
  draft of this plan did exactly that — it works, but it's an indirect trick that depends on an
  incidental quirk of unrelated code shared with Doorkeeper OAuth). Instead, keep this step's own
  "deny everything" decision entirely inside PAT's own code, as a direct, explicit branch — see
  step 8 below, which denies the request outright (the same way an expired token already is)
  instead of ever assigning an oauth_scope meant to be empty.
- `app/controllers/application_controller.rb` — specifically `find_user_by_pat_or_api_key` (~line
  176): `user.oauth_scope = pat.scope_list if pat.scope_list`. This only runs when `scope_list` is
  present (a scoped token); a blank-scope ("full access") token never sets `oauth_scope` at all,
  so `User#authorized_by_oauth?` stays false and `Role#allowed_to?` is called with no scope
  argument for it — unaffected by anything in this step.
- `app/controllers/settings_controller.rb` and `app/helpers/settings_helper.rb` — specifically
  `administration_settings_tabs`, `setting_multiselect`, and `notification_field`.
- `app/views/settings/` — specifically `_api.html.erb` (currently just `rest_api_enabled` and
  `jsonp_enabled`), `_notifications.html.erb` + the `notified_events` setting, and
  `_repositories.html.erb` + the `enabled_scm` setting.
- `config/settings.yml` — specifically the `personal_access_token_max_lifetime` entry (Step 1's
  scalar setting, comment style, `format: int`) and the `enabled_scm` / `notified_events` entries
  (serialized array settings).
- `app/views/my/new_personal_access_token.html.erb` and `app/views/roles/_form.html.erb` — the two
  existing places that render `Redmine::AccessControl` permissions grouped by `project_module`
  into checkboxes (`perms_by_module = permissions.group_by {|p| p.project_module.to_s}`, one
  `<fieldset>` per module, `toggle_checkboxes_link`, `check_all_links`, and a trailing
  `hidden_field_tag '...[]', ''` so submitting with everything unchecked still posts an empty
  array instead of omitting the key).

Design decisions (resolved — implement as specified, do not treat these as open questions):

1. **Setting name and storage format.** Add `personal_access_token_allowed_scopes` to
   `config/settings.yml`, declared as a serialized array, mirroring the EXACT declaration shape of
   `enabled_scm` / `notified_events` (`serialized: true`, `default:` an array literal):
   ```yaml
   # Permission names allowed as Personal Access Token scopes.
   # Empty (the default) means NONE are allowed - an admin must explicitly
   # check at least one permission below before any new Personal Access
   # Token can be created (Personal Access Tokens now require >= 1 scope).
   personal_access_token_allowed_scopes:
     serialized: true
     default: []
     security_notifications: 1
   ```
   `security_notifications: 1` is a deliberate addition (Step 1's own
   `personal_access_token_max_lifetime` doesn't have it, but this setting controls what a token
   can ultimately do instance-wide, the same class of concern as `rest_api_enabled`,
   `sys_api_enabled`, `mail_handler_api_enabled`, and `enabled_scm`, all of which already carry
   this flag — match them, not Step 1's scalar setting).

   Storage-pattern precedent, verified: `notified_events` and `enabled_scm` are the only two
   existing checkbox-array settings in this codebase (grepped `app/` for both). They're declared
   identically in `config/settings.yml` (`serialized: true` + array `default:`), so there's no
   difference between them on the *storage* side — pick either. On the *rendering* side they
   differ: `enabled_scm`'s partial (`app/views/settings/_repositories.html.erb`) renders a flat
   table over a small, fixed, hardcoded Ruby list (`Redmine::Scm::Base.all`, 5 entries) with extra
   per-row columns (scm command, version) that don't apply here. `notified_events`'s partial
   (`app/views/settings/_notifications.html.erb` + `SettingsHelper#notification_field`) renders a
   flat list of checkboxes over a large, dynamic, plugin-extensible collection
   (`Redmine::Notifiable.all`) with only a checked/unchecked state — structurally much closer to
   what this setting needs (a large, plugin-extensible collection —
   `Redmine::AccessControl.permissions.reject(&:public?)` is exactly this: ~140 entries in core,
   more with plugins — reduced to checked/unchecked). So `notified_events` is the closer
   structural match; follow its checkbox-per-item / `Setting.<name>.include?(name)` /
   `check_all_links` shape, but group by `project_module` (see decision 2) instead of
   `notified_events`' parent/child nesting, since project_module grouping is what Step 3's picker
   (the thing this setting must stay visually/behaviorally consistent with) already uses.

   Do NOT literally enumerate all current permission names into the YAML `default:` (the
   permission universe is computed at runtime by `Redmine::AccessControl.map` and varies with
   installed plugins) and do NOT special-case a blank/empty setting value to mean "unrestricted"
   anywhere in the code (see decision 3 — no sentinel, no `return full if configured.blank?`
   shortcut). An empty configured list is simply an empty list, computed the same way a
   non-empty one is: the intersection of the full permission universe with whatever's configured.
   Blank literally means "nothing is currently allowed," matching what an all-unchecked checkbox
   list means anywhere else in this application — there is no special case to reason about.

   **Deployment consequence, document it, don't work around it**: because blank means "nothing
   allowed" and this step also requires >= 1 scope per token, a fresh install (or an existing
   instance upgrading past this step) cannot create any new Personal Access Token until an admin
   visits Settings → API and checks at least one permission. This is intentional fail-closed
   behavior, not a bug to route around with a second setting or a "first run" special case. Make
   this unmissable in two places: (a) a locale-driven info line under the checkboxes on the
   Settings → API tab (new key, e.g. `text_personal_access_token_allowed_scopes_info`: something
   like "No permissions are allowed as personal access token scopes until at least one is checked
   here. Until then, users cannot create new personal access tokens."), and (b) a similar message
   in Step 3's own "New personal access token" form (`app/views/my/new_personal_access_token.html.erb`)
   whenever `PersonalAccessToken.allowed_permissions` is empty, shown INSTEAD of an empty,
   confusingly-blank checkbox area — e.g. "No permissions have been enabled for personal access
   tokens yet. Ask an administrator to enable at least one under Administration → Settings → API."
   (new locale key, e.g. `text_personal_access_token_no_allowed_scopes_configured`).

2. **Reuse Step 3's module-grouped checkbox rendering — extract a shared partial now.** Step 3's
   own plan explicitly left this as "extract a shared partial if cleanly possible without touching
   RolesController's own views, otherwise duplicate" and the Step 3 worker chose to duplicate (there
   are currently two independent copies of this rendering logic: `app/views/roles/_form.html.erb`
   lines ~52–71, and `app/views/my/new_personal_access_token.html.erb` lines ~13–32). This step adds
   a real second consumer *within the PAT feature itself* (this new Settings-tab checkbox UI), which
   changes the calculus: extracting now only requires touching PAT-owned views, not
   `RolesController`'s — the exact condition Step 3 said would make extraction "cleanly possible".
   Do extract:
   - New shared partial `app/views/common/_permission_checkboxes.html.erb` (this codebase already
     uses `app/views/common/` for cross-controller shared partials, e.g. `_tabs.html.erb` behind
     `render_tabs`/`administration_settings_tabs` — follow that precedent for location). Locals:
     `permissions` (an array of `Redmine::AccessControl::Permission`-like objects responding to
     `.name` and `.project_module`), `field_name` (the form field name prefix, e.g.
     `'personal_access_token[scopes]'` or `'settings[personal_access_token_allowed_scopes]'`), and
     `checked` (a `Proc`/lambda from a permission's `.name` to a boolean). Render the exact same
     module-grouped `<fieldset>` / `toggle_checkboxes_link` / `check_all_links` /
     trailing-empty-`hidden_field_tag` structure both existing copies already use.
   - Update `app/views/my/new_personal_access_token.html.erb` to render this partial instead of its
     current duplicated markup.
   - Do NOT touch `app/views/roles/_form.html.erb` or `RolesController`. That view's copy has an
     extra per-checkbox `:data => {:shows => ".#{permission.name}_shown"}` attribute (drives the
     issue-tracking-permissions-by-tracker UI further down that same form) that the PAT/Settings
     checkboxes don't need — forcing that view onto the new shared partial would mean either
     dropping that behavior or growing the partial's API to support it, neither of which this step
     needs. Leave `RolesController`'s copy exactly as Step 3 left it. Three total call sites
     (roles, My Account, admin settings) with one of them staying independent because its markup
     has a real behavioral difference is a reasonable outcome, not an inconsistency to fix here.

3. **Default value: nothing is allowed until an admin opts in (fails closed).** Add a class method
   on `PersonalAccessToken` that resolves the *effective* allowed permission list, used by every
   consumer in this step so there is exactly one place this logic lives:
   ```ruby
   # The permission names that may currently be used as Personal Access Token scopes -
   # the intersection of the real permission universe and whatever an admin has
   # explicitly enabled via Setting.personal_access_token_allowed_scopes. A blank/default
   # setting is simply an empty list here, same as any other empty configured list - it
   # is NOT special-cased to mean "unrestricted" (see the role.rb citation above for why
   # that kind of shortcut is exactly the mistake to avoid). No caching: reads Setting
   # fresh on every call, consistent with this feature's existing "no new caching layer"
   # trade-off (see the index plan doc).
   def self.allowed_permissions
     full = Redmine::AccessControl.permissions.reject(&:public?)
     configured = Array(Setting.personal_access_token_allowed_scopes).map(&:to_s)
     full.select {|permission| configured.include?(permission.name.to_s)}
   end

   def self.allowed_permission_names
     allowed_permissions.map(&:name)
   end
   ```
   This is a deliberate, resolved decision, not an oversight, and it deliberately REVERSES what an
   earlier draft of this plan recommended (defaulting to "unrestricted" to match Step 3's shipped
   behavior). Reasoning for fail-closed instead: the allow-list UI is a checkbox list, and a
   checkbox list that starts fully unchecked and grants everything by default would be a
   surprising, easy-to-miss security posture (silently permissive until someone notices and locks
   it down) — the safer default for something that gates what a long-lived, exportable credential
   can do is "explicitly enabled only." The real cost is operational, not architectural: covered in
   decision 1's deployment-consequence note and in this same method's lack of any blank-means-full
   special case. `Setting.personal_access_token_allowed_scopes` itself needs no cache of its own
   beyond `Setting`'s existing built-in `@cached_settings`/`check_cache` mechanism (already
   invalidated once per request by the existing `user_setup` before_action in
   `ApplicationController` — this is not a new caching layer, it's the same mechanism every other
   `Setting.*` read already goes through).

4. In `config/settings.yml`, add the `personal_access_token_allowed_scopes` entry exactly as shown
   in decision 1, placed near the existing `personal_access_token_max_lifetime` entry.

5. In `app/models/personal_access_token.rb`, add:
   - The two class methods from decision 3 (`allowed_permissions`, `allowed_permission_names`).
   - Two small instance methods used only for auth-time enforcement (step 8) — no sentinel value,
     just a direct, explicit computation of "what this token is currently allowed to do" and
     "has that become nothing":
     ```ruby
     # This token's scopes, narrowed to whatever the admin allow-list currently
     # permits (Setting.personal_access_token_allowed_scopes may have changed
     # since this token was created). An array, possibly empty.
     def effective_scope_list
       scope_list & self.class.allowed_permission_names
     end

     # True when every one of this token's scopes has since been disabled by
     # the admin allow-list, leaving nothing it can still do. Used to deny the
     # token outright (see ApplicationController#find_user_by_pat_or_api_key)
     # instead of assigning an empty oauth_scope - Role#allowed_permissions
     # treats [] the same as no scope at all (unrestricted), so an empty
     # effective_scope_list must be handled as an explicit denial, not passed
     # through as a scope value.
     def scopes_disabled?
       effective_scope_list.empty?
     end
     ```
     `scope_list` can no longer be `nil` for a persisted token once the validation below is in
     place (every token has ≥1 scope from now on), so `effective_scope_list` needs no
     nil-passthrough branch for a "blank means unrestricted" token.
   - Extend the model's existing presence validation to cover `scopes` too — no separate custom
     validation method needed, since `scopes.blank?` and `scope_list.blank?` are equivalent
     (`scope_list` returns `nil` exactly when `scopes` is blank):
     ```ruby
     validates_presence_of :name, :expires_on, :scopes
     ```
     This is a deliberate, universal behavior change from Step 3, which allowed blank `scopes` to
     mean "unrestricted/full access" with no validation at all. **There is no grandfathering
     exception here, by design**: Steps 1 through 5 of this feature are delivered together as one
     unit, not released incrementally with a real window where Step 3 was live in production on
     its own — so there is no pre-existing blank-scope token data for this validation to
     retroactively break. Going forward, every Personal Access Token requires ≥1 scope, full stop;
     a blank-scope "unrestricted" token is not a state this application can create at all anymore.
     (An earlier draft of this plan proposed an `on: :create`-scoped validation specifically to
     grandfather already-issued blank-scope tokens from Steps 1-3. That reasoning doesn't apply
     here — this whole feature ships as a single delivery — and it also broke every pre-existing
     Step 1-3 test that constructs a blank-scope token via `create!`. Fix those tests instead of
     reintroducing the grandfathering carve-out: give each one an explicit `:scopes => '...'`, and
     for the couple of tests whose actual point is to verify `scope_list`'s blank-handling
     (`test_scope_list_should_be_nil_when_scopes_is_blank` and similar), build an **unsaved**
     `PersonalAccessToken.new(...)` and call the method directly without `create!`/`save` — these
     are pure attribute-transformation methods that don't require persistence to test correctly,
     and an unsaved object never runs this validation.)

6. In `app/controllers/my_controller.rb`:
   - `new_personal_access_token`: change `@permissions = Redmine::AccessControl.permissions.reject(&:public?)`
     to `@permissions = PersonalAccessToken.allowed_permissions`. If this is empty (nothing enabled
     yet - the fail-closed default from decision 1/3), the view must render the
     `text_personal_access_token_no_allowed_scopes_configured` message from decision 1 instead of
     an empty, unexplained checkbox area.
   - `create_personal_access_token`: this is where the "copy of the admin-configured permissions at
     the time of creation" happens, and it's the ONLY place it happens — a token's persisted
     `scopes` is exactly the submitted names intersected with `PersonalAccessToken.allowed_permission_names`
     AS THEY STAND RIGHT NOW, computed once and then stored; nothing about the admin list is
     re-consulted again until the NEXT time this action runs for a different token. Do this
     intersection server-side, before assigning `scopes` (never trust the view alone to only
     render allowed checkboxes — a request can be crafted directly):
     ```ruby
     allowed_names = PersonalAccessToken.allowed_permission_names.map(&:to_s)
     submitted = Array(attrs[:scopes]).reject(&:blank?)
     @personal_access_token.scopes = (submitted & allowed_names).join(' ')
     ```
     If the intersection is empty (either because the user submitted nothing, or because
     everything they submitted has since been disabled by the admin), `scopes` ends up blank,
     which the model's new `scopes_required` validation (step 5) already catches — this
     deliberately reuses the SAME "at least one scope required" error rather than introducing a
     second, more confusing error message, per the requirement. Once saved, this stored value is
     the token's own record of what it was allowed to do at creation time; step 8 below is what
     re-checks it against the admin list again on every subsequent authenticated request.
   - Also update the `render :action => 'new_personal_access_token'` failure branch, which
     currently re-sets `@permissions = Redmine::AccessControl.permissions.reject(&:public?)` — change
     that one too, to `PersonalAccessToken.allowed_permissions`, so a re-rendered form after a
     validation error shows the same narrowed checkbox set as the original form.

7. Register the new checkbox UI on the "API" Settings tab
   (`app/views/settings/_api.html.erb`, tab name `api` in
   `SettingsHelper#administration_settings_tabs`) rather than adding a new tab. Verified there is no
   existing tab that's a closer fit, and no other tab in this codebase exists purely to host a
   single setting — adding a whole new tab for this one setting would be disproportionate next to
   the existing precedent. The "API" tab already exists specifically for API-authentication-adjacent
   toggles (`rest_api_enabled`, `jsonp_enabled`) and currently has very little content, making it
   the natural, lowest-friction home for "which permissions PATs may carry" (PATs are themselves an
   API authentication mechanism). No changes are needed to `administration_settings_tabs` itself
   (the `api` tab already exists) — only to the `_api.html.erb` partial's contents:
   ```erb
   <fieldset class="box" id="personal_access_token_allowed_scopes">
   <legend><%= l(:setting_personal_access_token_allowed_scopes) %></legend>
   <p class="text-muted"><%= l(:text_personal_access_token_allowed_scopes_info) %></p>
   <%= render :partial => 'common/permission_checkboxes',
              :locals => {
                :permissions => Redmine::AccessControl.permissions.reject(&:public?),
                :field_name => 'settings[personal_access_token_allowed_scopes]',
                :checked => lambda {|name| Setting.personal_access_token_allowed_scopes.include?(name.to_s)}
              } %>
   </fieldset>
   ```
   Note this passes the FULL permission universe here (not `PersonalAccessToken.allowed_permissions`)
   — the admin picking the allow-list needs to see and be able to (re-)select every real permission,
   including ones not currently allowed; only Step 3's own scope picker (step 6 above) should be
   narrowed to the currently-allowed subset.

8. In `app/controllers/application_controller.rb`, `find_user_by_pat_or_api_key`: enforce the
   CURRENT admin-allowed list at request time, not just at creation time, so that disabling a
   permission takes effect on a token's very next request without editing the token record. Do
   this as a **direct, explicit denial** — extend the same guard clause that already denies an
   expired token, rather than assigning some computed "empty" scope value and hoping downstream
   code interprets it as a denial:
   ```ruby
   def find_user_by_pat_or_api_key(key)
     if (pat = PersonalAccessToken.find_by_value(key)) && !pat.expired? && !pat.scopes_disabled?
       user = pat.user
       pat.touch_last_used!
       user.oauth_scope = pat.effective_scope_list if pat.scope_list
       user
     else
       User.find_by_api_key(key)
     end
   end
   ```
   `pat.scopes_disabled?` and `pat.effective_scope_list` (decision 5) both call
   `PersonalAccessToken.allowed_permission_names` fresh on every request here — no
   memoization/caching beyond `Setting`'s own existing per-request cache invalidation, same as step
   3/decision 3.

   What happens when every one of a token's original scopes has since been disabled:
   `pat.scopes_disabled?` is true, so this key is treated exactly like an expired or revoked one —
   the `if` condition is false, control falls to `User.find_by_api_key(key)` (which will also fail,
   since this is a PAT-shaped value), and the request ends up unauthenticated (401), the same
   outcome as every other "this credential doesn't currently work" case already handled here. This
   is a direct branch on a fact this step computes itself (`scopes_disabled?`), not a value handed
   to unrelated code (`Role#allowed_permissions`) in the hope it produces the right side effect —
   see the `role.rb` citation earlier in this prompt for exactly the trap this avoids: assigning a
   literal `[]` (or any value whose "deny everything" meaning depends on `Role#allowed_permissions`
   treating it a particular way) is fragile and indirect; denying the token outright, in this
   step's own guard clause, is not.

9. Do NOT auto-revoke a token when all its scopes become disabled, and do NOT add any admin or
   user notification for this. Deliberate, accepted trade-off, not an oversight — add it to the
   index plan doc's "Known trade-offs" section (see the separate edit below) rather than
   re-explaining it inline in every step. State explicitly in your report that future work may add
   proactive revocation and/or a notification when a token's scopes all become disabled, but that's
   out of scope here.

10. Add English locale strings to `config/locales/en.yml` for every new label/hint you introduce —
    at minimum `setting_personal_access_token_allowed_scopes` and
    `text_personal_access_token_allowed_scopes_info` (see decisions 1 and 7 for suggested wording).
    List every key you add in your final report. Check for an existing key with the same meaning
    before adding a duplicate (there is none currently — verified by grepping `en.yml` for
    `personal_access_token` and `setting_enabled_scm` during planning).

Verify — UI verification MUST be done with Playwright, not by reading code and not by manually
clicking through a browser yourself. This repo already has a standalone Playwright harness at
`playwright/` (see `playwright/README.md`) with `playwright.config.ts` pointed at
`http://localhost:3000` and a `loginAsAdmin(page)` helper in `playwright/tests/utils.ts`. **Because
the allow-list now fails closed by default, every test below that needs to create a scoped token
must first explicitly enable the permission(s) it needs** (via the Settings > API UI, or directly
via `docker compose exec -T redmine ... rails runner "Setting.personal_access_token_allowed_scopes = [...]"`
for setup convenience) — do not assume any permission is pre-allowed:
- Start the dev environment: `docker compose up -d` from the repo root.
- **Verified during planning: `playwright/tests/personal-access-tokens-admin.spec.ts` does NOT
  exist** (Step 4, which would introduce it, is plan-only and not implemented). Do not assume it
  exists and do not create a file with that exact name in this step — Step 4's own plan
  (`43881-04-admin-panel.md`) already calls for a file with that exact name, for the unrelated
  admin cross-user token CRUD/revoke panel, and claiming that name now would collide with Step 4
  landing later. Instead:
  - Extend the EXISTING `playwright/tests/personal-access-tokens.spec.ts` with:
    - A test that, with the allow-list still at its default (nothing enabled), navigates to "New
      personal access token" in My Account and asserts the empty-picker message
      (`text_personal_access_token_no_allowed_scopes_configured`) is shown instead of an empty
      checkbox area, and that submitting the form (no scopes possible) fails with a validation
      error and creates no token.
    - A test that, as an admin, navigates to Administration > Settings > API, checks a specific
      permission (pick one not otherwise used by this spec file's other tests, e.g. `log_time`),
      saves, then as a regular user navigates to "New personal access token" in My Account and
      asserts that permission's checkbox is now present and can be used to create a token scoped
      to it (assert on presence of the specific `#personal_access_token_scopes_log_time` checkbox
      and successful creation, not just "some checkboxes exist").
    - A test that then unchecks that same permission in Settings > API, saves, and asserts it's no
      longer present in the scope picker (assert on absence of that specific checkbox) — proving
      the allow-list is read fresh on every render, not cached from an earlier page load.
    - A test that creates a token scoped ONLY to a permission that is then disabled via Settings >
      API, then makes an authenticated API request using that token (e.g. `?key=<value>` against
      an action gated on that specific permission), and asserts it is now **unauthorized (401)**,
      not merely forbidden — this token is denied outright by
      `find_user_by_pat_or_api_key`'s guard clause (decision 8), the same way an expired or revoked
      token already is, proving the request-time enforcement from step 8, not just the
      creation-time filtering from step 6.
    - There is no "grandfathering" test here: a blank-scope, "unrestricted" token is not a state
      this application can create at all after this step (see decision 5) — there's no legacy data
      to prove continuity for, since Steps 1-5 ship together as one delivery. Do not add a test
      that constructs one via `PersonalAccessToken.create!(..., :scopes => nil)`; it would simply
      fail model validation, correctly.
  - Add these to the SAME file rather than a new one; there is no third PAT-adjacent screen being
    introduced here that would justify a new spec file (the admin allow-list lives on the existing
    Settings > API tab, which Playwright already knows how to reach as an admin).
- From `playwright/`: `npx playwright test`. All specs (including the pre-existing ones) must
  still pass — paste the actual terminal output in your final report, not a description of what
  you expect it to show.
- Add real Minitest coverage (this is in addition to, not instead of, the Playwright coverage
  above — Playwright proves the end-to-end UI/HTTP behavior, Minitest proves the model/controller
  logic directly and cheaply on every future run):
  - `test/unit/personal_access_token_test.rb`: following the exact style already there, add a test
    that blank scopes fails the model's `validates_presence_of` on create (no token is persisted),
    and update `test_scope_list_should_be_nil_when_scopes_is_blank` (and any similarly-purposed
    existing test) to build an **unsaved** `PersonalAccessToken.new(...)` rather than `create!`, per
    decision 5 — these test a pure attribute-transformation method, not a creatable state. Also add
    tests for `PersonalAccessToken.allowed_permissions`/`allowed_permission_names` (default/blank
    setting returns an EMPTY list, not the full one; a configured setting narrows the full list down
    to just what's configured; a configured setting containing a bogus/stale permission name that
    doesn't exist in `Redmine::AccessControl.permissions` is silently dropped, not raised or
    included), plus `effective_scope_list`/`scopes_disabled?` on a real (scoped) persisted token: a
    scoped token whose scope is currently allowed has a non-empty `effective_scope_list` and
    `scopes_disabled?` false; a scoped token whose scope is NOT/no-longer allowed has an empty
    `effective_scope_list` and `scopes_disabled?` true — use `with_settings` from `test_helper` the
    same way `settings_controller_test.rb` already does, e.g.
    `with_settings :personal_access_token_allowed_scopes => %w(view_issues) do ... end`.
  - `test/functional/my_controller_test.rb`: add tests for `create_personal_access_token` asserting
    (a) a request with no scopes selected fails with a validation error and no token is created,
    (b) a request whose submitted scopes are entirely outside the current allow-list fails with
    the SAME validation error (not a different one) and no token is created, (c) a request whose
    submitted scopes are a mix of allowed and disallowed names creates a token scoped ONLY to the
    allowed subset.
  - `test/integration/api_test/authentication_test.rb`: following the exact style of the existing
    `test_api_should_accept_auth_using_personal_access_token_scoped_to_a_permission_the_role_has` /
    `test_api_should_deny_auth_using_personal_access_token_scoped_away_from_a_permission_the_role_has`
    tests (same fixtures, same `with_settings`/`get "...?key=#{pat.value}"` shape), add a test
    where a token is created with a scope that IS currently allowed, the allow-list setting is then
    changed (via `with_settings :personal_access_token_allowed_scopes => [...]`) to exclude that
    scope, and a subsequent request with the SAME already-issued token gets `assert_response
    :unauthorized` — this is the one that actually exercises step 8's request-time re-check
    (`scopes_disabled?` denying the token outright), distinct from the creation-time tests above.
- Run `bundle exec rubocop app/models/personal_access_token.rb app/controllers/my_controller.rb
  app/controllers/application_controller.rb app/helpers/settings_helper.rb` (only include
  `settings_helper.rb` in that list if you actually end up changing it — the plan above doesn't
  require it, since `_api.html.erb` and the new shared partial don't need a new helper method, but
  double check once written).

Constraints:
- Do not touch `app/controllers/personal_access_tokens_controller.rb`,
  `app/views/personal_access_tokens/`, or `lib/redmine/preparation.rb`'s admin menu — none of that
  exists yet and none of it is this step's job (that's Step 4).
- Do not touch `app/views/roles/_form.html.erb` or `RolesController` (see decision 2).
- Do not special-case a blank/default `Setting.personal_access_token_allowed_scopes` to mean
  "unrestricted" anywhere (decision 1/3) — it means "nothing is allowed," with no exceptions. Do
  not add a second Setting to distinguish "never configured" from "deliberately emptied" — there is
  no such distinction to make.
- Do not introduce a sentinel/decoy permission name (or any other indirect trick relying on how
  `Role#allowed_permissions` treats an empty array) to represent "this token can do nothing" —
  deny the token directly in `find_user_by_pat_or_api_key`'s guard clause instead (decision 8).
- Do not add auto-revocation or a notification for a token whose scopes have all been disabled
  (decision 9) — that's explicitly out of scope for this step.
- Do not commit. Leave changes in the working tree for review.
```
