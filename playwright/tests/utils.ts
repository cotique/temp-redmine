import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { Page, expect } from '@playwright/test';

// Repo root, resolved relative to this file (see global-setup.ts for why not
// a relative `cwd`).
const REPO_ROOT = path.resolve(__dirname, '..', '..');

export const ADMIN_LOGIN = 'admin';
// Pinned by global-setup.ts (via `docker compose exec` + Rails, not the UI)
// before any test runs, so this is deterministic regardless of prior state in
// the persistent dev DB volume. Not a secret - a throwaway local sqlite dev
// database's admin password.
export const ADMIN_DEV_PASSWORD = 'RedmineDevVerify123!';

export const NON_ADMIN_LOGIN = 'pat-nonadmin-dev';
// Same story as ADMIN_DEV_PASSWORD: a throwaway local sqlite dev database's
// password, pinned deterministically before login rather than a secret.
export const NON_ADMIN_DEV_PASSWORD = 'RedmineDevVerifyNonAdmin123!';

/** Logs in as the dev admin account. Assumes global-setup.ts already pinned the password. */
export async function loginAsAdmin(page: Page): Promise<void> {
  await page.goto('/login');
  await page.fill('#username', ADMIN_LOGIN);
  await page.fill('#password', ADMIN_DEV_PASSWORD);
  await page.click('#login-submit');
  await expect(page.locator('#loggedas')).toBeVisible();
}

/**
 * Ensures a known non-admin test user exists in the dev DB with a known
 * password (creating it if this is the first run, otherwise reusing it and
 * resetting its password the same deterministic way global-setup.ts does for
 * admin), then logs in through the UI. Mirrors global-setup.ts's mechanism:
 * a `docker compose exec` + `rails runner` round-trip, not the UI, so this is
 * deterministic regardless of prior state in the persistent dev DB volume.
 */
export async function loginAsNonAdminUser(page: Page): Promise<void> {
  const script =
    `u = User.find_by_login('${NON_ADMIN_LOGIN}'); ` +
    `u ||= User.new(login: '${NON_ADMIN_LOGIN}', firstname: 'PAT', lastname: 'NonAdmin', ` +
    `mail: '${NON_ADMIN_LOGIN}@example.test'); ` +
    `u.admin = false; ` +
    `u.status = User::STATUS_ACTIVE; ` +
    `u.password = ENV['DEV_NONADMIN_PASSWORD']; ` +
    `u.password_confirmation = ENV['DEV_NONADMIN_PASSWORD']; ` +
    `u.must_change_passwd = false; ` +
    `u.save!(validate: false)`;

  execFileSync(
    'docker',
    ['compose', 'exec', '-T', '-e', `DEV_NONADMIN_PASSWORD=${NON_ADMIN_DEV_PASSWORD}`, 'redmine',
      'bundle', 'exec', 'rails', 'runner', script],
    { cwd: REPO_ROOT, stdio: 'inherit' },
  );

  await page.goto('/login');
  await page.fill('#username', NON_ADMIN_LOGIN);
  await page.fill('#password', NON_ADMIN_DEV_PASSWORD);
  await page.click('#login-submit');
  await expect(page.locator('#loggedas')).toBeVisible();
}
