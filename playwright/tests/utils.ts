import { Page, expect } from '@playwright/test';

export const ADMIN_LOGIN = 'admin';
// Pinned by global-setup.ts (via `docker compose exec` + Rails, not the UI)
// before any test runs, so this is deterministic regardless of prior state in
// the persistent dev DB volume. Not a secret - a throwaway local sqlite dev
// database's admin password.
export const ADMIN_DEV_PASSWORD = 'RedmineDevVerify123!';

/** Logs in as the dev admin account. Assumes global-setup.ts already pinned the password. */
export async function loginAsAdmin(page: Page): Promise<void> {
  await page.goto('/login');
  await page.fill('#username', ADMIN_LOGIN);
  await page.fill('#password', ADMIN_DEV_PASSWORD);
  await page.click('#login-submit');
  await expect(page.locator('#loggedas')).toBeVisible();
}
