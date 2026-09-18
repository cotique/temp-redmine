# UI verification harness (Playwright)

Standalone Playwright project for verifying UI changes against the local Redmine dev server
started from the repo root (`docker compose up -d`, see `../docker-compose.yml`). This is **not**
part of the Rails app or its own test suite (`test/system` still uses Capybara/Selenium) — it's a
separate, lightweight tool used by `/orchestrate` worker sessions (and anyone else) to actually
drive the browser when a plan's verification step says "verify in the UI."

## Setup (once)

```bash
cd playwright
npm install
npx playwright install chromium
```

## Running

Make sure the dev server is up first (`docker compose up -d` from the repo root), then:

```bash
cd playwright
npx playwright test
```

`global-setup.ts` runs once before the suite and pins the dev DB's `admin` account password via
`docker compose exec ... rails runner` (not through the UI) — see the comment in that file for why.
This makes login deterministic regardless of Redmine's forced first-login password-change flow or
any prior manual testing against the same persistent dev DB volume.

Use `loginAsAdmin(page)` from `tests/utils.ts` in any new spec that needs to be logged in.

## Adding a new verification spec

Add a `*.spec.ts` file under `tests/`. Keep specs scoped to one feature/flow being verified — this
harness is meant for ad hoc, per-change verification, not a growing regression suite.
