import { test, expect } from '@playwright/test';
import { loginAsAdmin } from './utils';

test('home page loads', async ({ page }) => {
  await page.goto('/');
  await expect(page).toHaveTitle(/Redmine/);
});

test('admin can log in', async ({ page }) => {
  await loginAsAdmin(page);
  await page.goto('/my/account');
  await expect(page.locator('#loggedas')).toContainText('admin');
});
