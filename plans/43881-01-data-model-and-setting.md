# #43881 — Step 1: Data model + Setting

Part of [Personal Access Tokens](43881-personal-access-tokens.md). 

---

```
Repo: this Redmine checkout (Ruby on Rails). Branch: stay on the current branch (test-43881), do not create a new branch, do not commit.

Goal: add the data model for Personal Access Tokens (PAT) — no auth wiring, no UI yet. That's later steps.

1. Add a migration (follow the exact naming/timestamp convention of the existing files in db/migrate/ — check the most recent one for the format) creating table `personal_access_tokens`:
   - id
   - user_id (integer, not null, indexed, references users)
   - name (string, not null) — user-chosen label for the token
   - token_digest (string, not null, indexed, unique) — SHA256 hex digest of the token value; the raw value is NEVER stored
   - scopes (string, nullable) — space-separated permission names (e.g. "view_issues edit_issues"); blank/nil means unrestricted (same privileges as the user's roles)
   - expires_on (date, not null) — mandatory expiration, enforced at the model level too
   - last_used_on (datetime, nullable)
   - created_on (datetime, not null)

   Also add a composite UNIQUE index on `[:user_id, :name]` in this same migration. The model-level `validates_uniqueness_of :name, scope: :user_id` in step 2 below is not race-condition-safe on its own (two concurrent requests can both pass the AR validation before either commits) — per Rails' own guidance, a uniqueness validation must be backed by a DB-level unique index to actually guarantee the constraint, exactly like `token_digest` already has one.

2. Add `app/models/personal_access_token.rb`:
   - `belongs_to :user`
   - `validates_presence_of :name, :expires_on`
   - `validates_uniqueness_of :name, scope: :user_id` (a user can't have two tokens with the same name; this is a friendly-error convenience on top of the DB-level unique index from step 1, not a substitute for it)
   - `before_create` callback that generates the raw token value, stores only its SHA256 hex digest in `token_digest`, and exposes the ONE-TIME raw value via a non-persisted `attr_accessor :value` so the controller can display it once after creation. Raw value format: a short recognizable prefix (e.g. `redmine-pat-`, similar in spirit to how GitHub/GitLab prefix their personal access tokens — pick whatever reads cleanest) + `Redmine::Utils.random_hex(20)` (reuse `Redmine::Utils.random_hex`, the same helper `Token.generate_token_value` in app/models/token.rb already uses — do not invent a new random-string helper).
   - Class method `self.find_by_value(raw_value)`: computes the SHA256 digest of `raw_value` and looks up by `token_digest` using `ActiveSupport::SecurityUtils.secure_compare` semantics for the digest comparison (Digest::SHA256.hexdigest is already fixed-length/constant enough, but compare via secure_compare against the found record's digest before returning it, mirroring how `Token.find_token` in app/models/token.rb double-checks with `ActiveSupport::SecurityUtils.secure_compare` after the DB lookup).
   - Instance method `expired?` → `expires_on < Date.today`.
   - Instance method `scope_list` → returns `scopes.to_s.split(' ').map(&:to_sym)`, or `nil`/empty if `scopes` is blank (blank must mean "no restriction", not "no permissions" — do not return an empty array that would deny everything).
   - Instance method `touch_last_used!` → updates `last_used_on` to current time, using `update_column` (no validation/callbacks) so this doesn't run into the expiration/uniqueness validations on every API call.
   - Do NOT implement any "import legacy API tokens" migration helper — explicitly out of scope for this step.

3. Add `has_many :personal_access_tokens, dependent: :destroy` on `app/models/user.rb` (find the existing `has_many :tokens` or similar association there and place it near it).

4. Add setting `personal_access_token_max_lifetime` to `config/settings.yml`, following the exact format of an existing `format: int` setting already in that file (e.g. copy the shape used by an existing integer setting — read the file first to match indentation/keys exactly). Default value: `0` (meaning "no limit"). This setting is NOT enforced yet in this step — that comes in Step 3's create form. Just get the setting itself registered and available via `Setting.personal_access_token_max_lifetime`.

5. Add English locale strings needed so far to `config/locales/en.yml` (follow existing alphabetical/grouped placement conventions in that file):
   - `setting_personal_access_token_max_lifetime: "Maximum personal access token lifetime (days)"`
   - `field_personal_access_token: "Personal access token"`

Verify:
- Run the migration: `bundle exec rake db:migrate` and confirm it applies cleanly with no errors.
- Open a Rails console (`bundle exec rails console`) and manually exercise the model: create a `PersonalAccessToken` for an existing user with `name: "test"`, `expires_on: 30.days.from_now`, confirm `.value` returns the one-time raw string, confirm `PersonalAccessToken.find_by_value(that_value)` returns the same record, confirm `token_digest` in the DB is NOT the raw value, confirm `.expired?` is false, and confirm `PersonalAccessToken.find_by_value("garbage")` returns nil.
- In the same console session, confirm the `[:user_id, :name]` uniqueness is actually enforced at the DB level, not just by the AR validation: build a second record with the same user_id/name and `.save(validate: false)` it (bypassing the model validation on purpose) — this must raise `ActiveRecord::RecordNotUnique`, proving the DB index is really there and doing the work.
- Run `bundle exec rubocop app/models/personal_access_token.rb app/models/user.rb db/migrate/*personal_access_tokens*.rb` and fix any offenses.

Constraints:
- Do not touch ApplicationController, MyController, routes.rb, or any view — those are later steps.
- Do not introduce any new gem.
- Do not commit anything. Leave changes in the working tree for review.
- If anything here conflicts with an existing pattern you find in the codebase (e.g. a different helper already does SHA256 hashing, or `Redmine::Utils` doesn't have `random_hex`), stop and report the conflict instead of improvising a workaround.
```
