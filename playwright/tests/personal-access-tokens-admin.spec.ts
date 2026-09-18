import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { test, expect, Page } from '@playwright/test';
import { loginAsAdmin, loginAsNonAdminUser, ADMIN_LOGIN, ADMIN_DEV_PASSWORD, NON_ADMIN_LOGIN } from './utils';

// Repo root, resolved relative to this file (see global-setup.ts for why not
// a relative `cwd`).
const REPO_ROOT = path.resolve(__dirname, '..', '..');

/** Runs a Ruby snippet inside the running dev container via `rails runner`. */
function railsRunner(script: string): void {
  execFileSync(
    'docker',
    ['compose', 'exec', '-T', 'redmine', 'bundle', 'exec', 'rails', 'runner', script],
    { cwd: REPO_ROOT, stdio: 'inherit' },
  );
}

function uniqueName(prefix: string): string {
  return `${prefix}-${Date.now()}-${Math.floor(Math.random() * 1000)}`;
}

/**
 * Creates a token for whichever user `page` is currently logged in as, via
 * the My Account UI. Assumes the caller has already admin-allowed
 * 'view_issues' as a Personal Access Token scope (fail-closed default: at
 * least one scope must be checked, or the token can't be created at all).
 */
async function createTokenViaMyAccount(page: Page, name: string): Promise<void> {
  await page.goto('/my/personal_access_tokens/new');
  await page.fill('#personal_access_token_name', name);
  const expiresOn = new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString().slice(0, 10);
  await page.fill('#personal_access_token_expires_on', expiresOn);
  await page.check('#personal_access_token_scopes_view_issues');
  await page.click('input[type=submit]');
  await expect(page).toHaveURL(/\/my\/personal_access_tokens$/);
}

test.describe('Personal access tokens (Administration)', () => {
  test('admin can view and revoke any user\'s tokens; a non-admin is denied', async ({ page, browser }) => {
    // Several docker-exec round-trips plus a fair number of UI steps below;
    // the default 30s test timeout is too tight for that.
    test.setTimeout(120_000);

    // Fail-closed default: at least one permission must be admin-allowed
    // before any new token (scoped or not) can be created at all.
    railsRunner("Setting.personal_access_token_allowed_scopes = ['view_issues']");

    // --- Tokens for the admin account, created via My Account (Step 3 UI) ---
    await loginAsAdmin(page);
    const adminTokenName1 = uniqueName('admin-token');
    await createTokenViaMyAccount(page, adminTokenName1);
    const adminTokenName2 = uniqueName('admin-token');
    await createTokenViaMyAccount(page, adminTokenName2);

    // --- A token for the non-admin user, in a separate browser context so
    // both sessions are live at once ---
    const nonAdminContext = await browser.newContext();
    const nonAdminPage = await nonAdminContext.newPage();
    await loginAsNonAdminUser(nonAdminPage);
    const nonAdminTokenName = uniqueName('nonadmin-token');
    await createTokenViaMyAccount(nonAdminPage, nonAdminTokenName);

    // --- Administration menu entry is present and navigates to the new page ---
    await page.goto('/admin');
    const menuLink = page.locator('#admin-menu').getByRole('link', { name: 'Personal access tokens' });
    await expect(menuLink).toBeVisible();
    await menuLink.click();
    await expect(page).toHaveURL(/\/personal_access_tokens$/);

    // --- Listing shows tokens belonging to both users ---
    // per_page=100 rather than relying on the default: Setting.per_page_options
    // is a global, persisted setting, and this suite's own pagination tests
    // (in this file and personal-access-tokens.spec.ts) deliberately shrink it
    // to make "2" the smallest/default option, which would otherwise hide
    // these rows on page 2 depending on what ran before this test.
    await page.goto('/personal_access_tokens?per_page=100');
    await expect(page.locator('table.personal-access-tokens')).toBeVisible();
    await expect(page.locator('tr', { hasText: adminTokenName1 })).toHaveCount(1);
    await expect(page.locator('tr', { hasText: adminTokenName2 })).toHaveCount(1);
    const nonAdminRow = page.locator('tr', { hasText: nonAdminTokenName });
    await expect(nonAdminRow).toHaveCount(1);
    await expect(nonAdminRow.locator('td.user')).toContainText(NON_ADMIN_LOGIN);
    await expect(page.locator('tr', { hasText: adminTokenName1 }).locator('td.user')).toContainText(ADMIN_LOGIN);

    // --- Force pagination across both users' tokens without creating dozens
    // of real tokens through the UI ---
    railsRunner("Setting.per_page_options = '2,25,50,100'");
    const pagePrefix = uniqueName('page-token');
    railsRunner(`
      admin = User.find_by_login('${ADMIN_LOGIN}')
      nonadmin = User.find_by_login('${NON_ADMIN_LOGIN}')
      3.times do |i|
        admin.personal_access_tokens.create!(name: "${pagePrefix}-admin-#{i}", expires_on: 30.days.from_now.to_date, scopes: 'view_issues')
        nonadmin.personal_access_tokens.create!(name: "${pagePrefix}-nonadmin-#{i}", expires_on: 30.days.from_now.to_date, scopes: 'view_issues')
      end
    `);

    await page.goto('/personal_access_tokens?per_page=2');
    const rows = page.locator('table.personal-access-tokens tbody tr');
    await expect(rows).toHaveCount(2);
    const page1Names = await rows.allInnerTexts();

    const pager = page.locator('span.pagination');
    await expect(pager).toBeVisible();
    // Exact-match the page-2 link: the "per page: 2, 25, 50, 100" links also
    // render "2" as visible text, and a substring match would be ambiguous.
    await pager.getByRole('link', { name: '2', exact: true }).click();

    await expect(page).toHaveURL(/[?&]page=2\b/);
    const page2Rows = page.locator('table.personal-access-tokens tbody tr');
    await expect(page2Rows.first()).toBeVisible();
    const page2Names = await page2Rows.allInnerTexts();
    expect(page2Names.join('|')).not.toBe(page1Names.join('|'));

    // --- Revoke one token from the admin panel ---
    // The destroy action is sudo-gated (mirrors RolesController#destroy), and
    // the dev config shortens the sudo timeout to 1 minute so Step 3's own
    // spec can prove re-authentication is enforced. The docker-exec round
    // trips above can alone eat well over a minute, so sudo may or may not
    // still be active by now - refresh it explicitly rather than assume
    // either way (mirrors the re-authentication flow in
    // personal-access-tokens.spec.ts).
    await page.goto('/my/personal_access_tokens');
    const sudoForm = page.locator('form#sudo-form');
    if (await sudoForm.isVisible()) {
      await sudoForm.locator('#sudo_password').fill(ADMIN_DEV_PASSWORD);
      await sudoForm.locator('input[type=submit]').click();
    }

    // per_page=100 keeps this deterministic regardless of where adminTokenName1
    // sorts among the now-larger token set, and regardless of the per_page
    // value the session picked up from the pagination steps above.
    await page.goto('/personal_access_tokens?per_page=100');
    const targetRow = page.locator('tr', { hasText: adminTokenName1 });
    await expect(targetRow).toBeVisible();
    page.once('dialog', dialog => dialog.accept());
    await targetRow.locator('a.icon-del').click();
    await expect(page).toHaveURL(/\/personal_access_tokens/);
    await expect(page.locator('tr', { hasText: adminTokenName1 })).toHaveCount(0);

    // --- A non-admin hitting the admin URL directly is denied ---
    const response = await nonAdminPage.goto('/personal_access_tokens');
    expect(response?.status()).toBe(403);
    await expect(nonAdminPage.locator('body')).toContainText(/not authorized/i);

    await nonAdminContext.close();
  });
});
