import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { test, expect } from '@playwright/test';
import { loginAsAdmin, loginAsNonAdminUser, ADMIN_LOGIN, ADMIN_DEV_PASSWORD, NON_ADMIN_LOGIN } from './utils';

// Repo root, resolved relative to this file (see global-setup.ts for why not
// a relative `cwd`).
const REPO_ROOT = path.resolve(__dirname, '..', '..');

/** Runs a Ruby snippet inside the running dev container via `rails runner`. */
function railsRunner(script: string): string {
  return execFileSync(
    'docker',
    ['compose', 'exec', '-T', 'redmine', 'bundle', 'exec', 'rails', 'runner', script],
    { cwd: REPO_ROOT, encoding: 'utf-8' },
  );
}

// The dev config (config/configuration.yml, local-only) pins sudo_mode_timeout
// to 1 minute so this spec can prove re-authentication is actually enforced
// without waiting on the 15-minute production default.
const SUDO_TIMEOUT_MS = 65_000;

function uniqueName(prefix: string): string {
  return `${prefix}-${Date.now()}-${Math.floor(Math.random() * 1000)}`;
}

test.describe('Personal access tokens (My account)', () => {
  test('create shows the raw value once; reloading the list does not duplicate or re-reveal it', async ({ page }) => {
    // Fail-closed default: at least one permission must be admin-allowed
    // before any new token (scoped or not) can be created at all.
    railsRunner("Setting.personal_access_token_allowed_scopes = ['view_issues']");

    await loginAsAdmin(page);

    await page.goto('/my/account');
    await page.click('text=Personal access tokens');
    await expect(page).toHaveURL(/\/my\/personal_access_tokens/);

    await page.click('text=New personal access token');
    await expect(page).toHaveURL(/\/my\/personal_access_tokens\/new/);

    const tokenName = uniqueName('reveal-token');
    await page.fill('#personal_access_token_name', tokenName);
    const expiresOn = new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString().slice(0, 10);
    await page.fill('#personal_access_token_expires_on', expiresOn);
    await page.check('#personal_access_token_scopes_view_issues');
    await page.click('input[type=submit]');

    // Redirected to the list, with the raw value shown exactly once.
    await expect(page).toHaveURL(/\/my\/personal_access_tokens$/);
    const banner = page.locator('#personal-access-token-value');
    await expect(banner).toBeVisible();
    const tokenValueText = (await banner.locator('pre').innerText()).trim();
    expect(tokenValueText).toMatch(/^redmine-pat-/);

    const rowCountBefore = await page.locator('table.personal-access-tokens tbody tr').count();
    await expect(page.locator(`tr:has-text("${tokenName}")`)).toHaveCount(1);

    // Reloading the same list URL must NOT resubmit the create form: the
    // value banner must disappear and no second token must be created.
    await page.reload();
    await expect(page.locator('#personal-access-token-value')).toHaveCount(0);
    const rowCountAfter = await page.locator('table.personal-access-tokens tbody tr').count();
    expect(rowCountAfter).toBe(rowCountBefore);
    await expect(page.locator(`tr:has-text("${tokenName}")`)).toHaveCount(1);
  });

  test('list shows the correct name, expiration and scope for a scoped token', async ({ page }) => {
    railsRunner("Setting.personal_access_token_allowed_scopes = ['view_issues']");

    await loginAsAdmin(page);

    await page.goto('/my/personal_access_tokens/new');

    const tokenName = uniqueName('scoped-token');
    await page.fill('#personal_access_token_name', tokenName);
    const expiresOn = new Date(Date.now() + 10 * 24 * 60 * 60 * 1000).toISOString().slice(0, 10);
    await page.fill('#personal_access_token_expires_on', expiresOn);
    // Pick one well-known, always-available permission checkbox so the
    // token is scope-restricted rather than full-access.
    await page.check('#personal_access_token_scopes_view_issues');
    await page.click('input[type=submit]');

    await expect(page).toHaveURL(/\/my\/personal_access_tokens$/);
    const row = page.locator('tr', { hasText: tokenName });
    await expect(row).toBeVisible();
    await expect(row.locator('td.expires_on')).toHaveText(new RegExp(String(new Date(expiresOn).getFullYear())));
    await expect(row.locator('td.scopes')).not.toHaveText(/Full access/);
  });

  test('pagination: more tokens than fit on one page produce a working pager', async ({ page }) => {
    // The two `docker compose exec` round-trips below (each booting a Rails
    // runner process) can alone take longer than the default 30s test
    // timeout.
    test.setTimeout(90_000);

    // Make a small per_page option available (the app only honors values
    // from Setting.per_page_options_array) so we don't have to create 26+
    // real tokens through the UI just to force a second page.
    railsRunner("Setting.per_page_options = '2,25,50,100'");

    const namePrefix = uniqueName('page-token');
    railsRunner(`
      u = User.find_by_login('${ADMIN_LOGIN}')
      3.times do |i|
        u.personal_access_tokens.create!(name: "${namePrefix}-#{i}", expires_on: 30.days.from_now.to_date, scopes: 'view_issues')
      end
    `);

    await loginAsAdmin(page);
    await page.goto('/my/personal_access_tokens?per_page=2');

    const rows = page.locator('table.personal-access-tokens tbody tr');
    await expect(rows).toHaveCount(2);
    const page1Names = await rows.allInnerTexts();

    const pager = page.locator('span.pagination');
    await expect(pager).toBeVisible();
    // Exact-match the page-2 link: the "per page: 2, 25" links also render
    // "2"/"25" as visible text, and either a substring text match or a
    // substring href match ("per_page=25" contains "page=2") would be
    // ambiguous.
    await pager.getByRole('link', { name: '2', exact: true }).click();

    await expect(page).toHaveURL(/[?&]page=2\b/);
    const page2Rows = page.locator('table.personal-access-tokens tbody tr');
    await expect(page2Rows.first()).toBeVisible();
    const page2Names = await page2Rows.allInnerTexts();
    expect(page2Names.join('|')).not.toBe(page1Names.join('|'));
  });

  test('sudo mode is enforced on personal access token actions after it expires', async ({ page }) => {
    test.setTimeout(120_000);

    await loginAsAdmin(page);
    // Sudo is active immediately post-login (same as show_api_key /
    // reset_api_key). Let it expire per the (locally shortened) timeout.
    await page.waitForTimeout(SUDO_TIMEOUT_MS);

    await page.goto('/my/personal_access_tokens');

    // The list action itself requires sudo mode, so instead of the list we
    // should see the same re-authentication prompt used elsewhere in the app.
    const sudoForm = page.locator('form#sudo-form');
    await expect(sudoForm).toBeVisible();
    await expect(page.locator('body')).toContainText(/Confirm your password|password required/i);

    await sudoForm.locator('#sudo_password').fill(ADMIN_DEV_PASSWORD);
    await sudoForm.locator('input[type=submit]').click();

    // Sudo re-established: the originally requested page is now served.
    await expect(page).toHaveURL(/\/my\/personal_access_tokens/);
    await expect(page.locator('table.personal-access-tokens')).toBeVisible();
  });

  test('revoking a token via the UI removes it from the list', async ({ page }) => {
    railsRunner("Setting.personal_access_token_allowed_scopes = ['view_issues']");

    await loginAsAdmin(page);

    await page.goto('/my/personal_access_tokens/new');
    const tokenName = uniqueName('revoke-token');
    await page.fill('#personal_access_token_name', tokenName);
    const expiresOn = new Date(Date.now() + 5 * 24 * 60 * 60 * 1000).toISOString().slice(0, 10);
    await page.fill('#personal_access_token_expires_on', expiresOn);
    await page.check('#personal_access_token_scopes_view_issues');
    await page.click('input[type=submit]');

    await expect(page).toHaveURL(/\/my\/personal_access_tokens$/);
    const row = page.locator('tr', { hasText: tokenName });
    await expect(row).toBeVisible();

    page.once('dialog', dialog => dialog.accept());
    await row.locator('a.icon-del').click();

    await expect(page).toHaveURL(/\/my\/personal_access_tokens$/);
    await expect(page.locator('tr', { hasText: tokenName })).toHaveCount(0);
  });

  test('with nothing admin-allowed, "New personal access token" shows the empty-picker message and blocks creation', async ({ page }) => {
    railsRunner('Setting.personal_access_token_allowed_scopes = []');

    await loginAsAdmin(page);
    await page.goto('/my/personal_access_tokens/new');

    await expect(page.locator('body')).toContainText(/No permissions have been enabled for personal access tokens yet/i);
    await expect(page.locator('#personal_access_token_scopes fieldset')).toHaveCount(0);

    const tokenName = uniqueName('no-scopes-allowed');
    await page.fill('#personal_access_token_name', tokenName);
    const expiresOn = new Date(Date.now() + 10 * 24 * 60 * 60 * 1000).toISOString().slice(0, 10);
    await page.fill('#personal_access_token_expires_on', expiresOn);
    await page.click('input[type=submit]');

    // No scopes were possible to submit, so the create fails validation and
    // re-renders the form instead of redirecting to the list.
    await expect(page.locator('#errorExplanation')).toBeVisible();

    await page.goto('/my/personal_access_tokens');
    await expect(page.locator('tr', { hasText: tokenName })).toHaveCount(0);
  });

  test('admin enables a permission for PAT scopes; a user can then create a token scoped to it, and disabling it again removes it from the picker', async ({ page, browser }) => {
    test.setTimeout(90_000);
    railsRunner('Setting.personal_access_token_allowed_scopes = []');

    // --- Admin enables `log_time` on Settings > API ---
    await loginAsAdmin(page);
    await page.goto('/settings/edit?tab=api');
    await page.check('#settings_personal_access_token_allowed_scopes_log_time');
    // Every settings tab's form (and submit button) is present in the DOM at
    // once, hidden via inline style except the active one - `input[type=submit]`
    // alone would resolve to the first (hidden) tab's button instead of this one.
    await page.click('#tab-content-api input[type=submit]');
    await expect(page).toHaveURL(/\/settings/);
    await expect(page.locator('#settings_personal_access_token_allowed_scopes_log_time')).toBeChecked();

    // --- A regular (non-admin) user can now see and use that scope ---
    const nonAdminContext = await browser.newContext();
    const nonAdminPage = await nonAdminContext.newPage();
    await loginAsNonAdminUser(nonAdminPage);
    await nonAdminPage.goto('/my/personal_access_tokens/new');
    await expect(nonAdminPage.locator('#personal_access_token_scopes_log_time')).toBeVisible();

    const tokenName = uniqueName('log-time-scope');
    await nonAdminPage.fill('#personal_access_token_name', tokenName);
    const expiresOn = new Date(Date.now() + 10 * 24 * 60 * 60 * 1000).toISOString().slice(0, 10);
    await nonAdminPage.fill('#personal_access_token_expires_on', expiresOn);
    await nonAdminPage.check('#personal_access_token_scopes_log_time');
    await nonAdminPage.click('input[type=submit]');
    await expect(nonAdminPage).toHaveURL(/\/my\/personal_access_tokens$/);
    await expect(nonAdminPage.locator('tr', { hasText: tokenName })).toBeVisible();

    // --- Admin disables it again ---
    await page.goto('/settings/edit?tab=api');
    await page.uncheck('#settings_personal_access_token_allowed_scopes_log_time');
    await page.click('#tab-content-api input[type=submit]');
    await expect(page).toHaveURL(/\/settings/);
    await expect(page.locator('#settings_personal_access_token_allowed_scopes_log_time')).not.toBeChecked();

    // --- The picker no longer offers it - proves the allow-list is read
    // fresh on every render, not cached from the earlier page load ---
    await nonAdminPage.goto('/my/personal_access_tokens/new');
    await expect(nonAdminPage.locator('#personal_access_token_scopes_log_time')).toHaveCount(0);

    await nonAdminContext.close();
  });

  test('a token scoped to a permission that is later disabled via Settings > API is denied (401), not merely forbidden, on its next API request', async ({ page, request }) => {
    test.setTimeout(60_000);
    railsRunner("Setting.personal_access_token_allowed_scopes = ['log_time']");
    // This dev DB has no demo data (no projects/roles/activities), and the
    // REST API is off by default - all needed here for a genuine end-to-end
    // authenticated request, not just for the PAT scoping under test. Uses
    // the non-admin dev user (not admin): a scoped PAT strips the usual
    // admin bypass (see User#admin?), and admin isn't a member of any
    // project, so a scoped admin token would be denied for an unrelated
    // reason instead of the one this test is proving.
    const tokenName = uniqueName('log-time-then-disabled');
    const projectIdentifier = uniqueName('pat-scope-test').toLowerCase();
    const setupOut = railsRunner(`
      Setting.rest_api_enabled = '1'
      activity = TimeEntryActivity.first || TimeEntryActivity.create!(name: 'PAT Scope Test Activity')
      project = Project.create!(name: 'PAT Scope Test', identifier: '${projectIdentifier}')
      project.enabled_module_names = ['time_tracking']
      role = Role.create!(name: "${projectIdentifier}-role", permissions: [:log_time])
      user = User.find_by_login('${NON_ADMIN_LOGIN}')
      Member.create!(project: project, user: user, roles: [role])
      pat = user.personal_access_tokens.create!(name: "${tokenName}", expires_on: 30.days.from_now.to_date, scopes: 'log_time')
      puts "#{project.id}|#{activity.id}|#{pat.value}"
    `);
    const [projectId, activityId, tokenValue] = setupOut.trim().split('\n').filter(Boolean).pop()!.split('|');

    const timeEntryParams = {
      time_entry: {project_id: projectId, hours: 1, activity_id: activityId, spent_on: new Date().toISOString().slice(0, 10)},
    };

    // Works while `log_time` is still admin-allowed.
    const okResponse = await request.post(`/time_entries.xml?key=${tokenValue}`, {data: timeEntryParams});
    expect(okResponse.status()).toBe(201);

    // Admin disables `log_time` via Settings > API.
    await loginAsAdmin(page);
    await page.goto('/settings/edit?tab=api');
    await page.uncheck('#settings_personal_access_token_allowed_scopes_log_time');
    await page.click('#tab-content-api input[type=submit]');
    await expect(page.locator('#settings_personal_access_token_allowed_scopes_log_time')).not.toBeChecked();

    // The same already-issued token is now denied outright (401), not 403.
    const deniedResponse = await request.post(`/time_entries.xml?key=${tokenValue}`, {data: timeEntryParams});
    expect(deniedResponse.status()).toBe(401);
  });
});
