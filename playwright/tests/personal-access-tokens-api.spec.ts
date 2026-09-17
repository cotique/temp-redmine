import { test, expect, APIRequestContext } from '@playwright/test';
import { execFileSync } from 'node:child_process';
import path from 'node:path';

// There is no UI for Personal Access Tokens yet (Steps 3/4 of
// plans/43881-personal-access-tokens.md aren't built) - this exercises the
// Step 2 authentication wiring directly via the API, the same way Step 2's
// own verification did via curl, but as a real repeatable Playwright spec.

const REPO_ROOT = path.resolve(__dirname, '..', '..');

interface Fixtures {
  project_id: string;
  valid_key: string;
  expired_key: string;
  scoped_key: string;
  revoked_key: string;
  legacy_api_key: string;
}

function setupFixtures(): Fixtures {
  const script = `
    require 'json'
    User.find_by_login('pat_playwright_tester')&.destroy
    Project.find_by_identifier('pat-playwright-project')&.destroy
    Role.find_by_name('PAT Playwright Role')&.destroy

    project = Project.create!(name: 'PAT Playwright Project', identifier: 'pat-playwright-project', is_public: false)
    role = Role.create!(name: 'PAT Playwright Role', permissions: [:view_issues, :edit_issues])
    user = User.create!(login: 'pat_playwright_tester', firstname: 'PAT', lastname: 'Tester',
                         mail: 'pat_playwright_tester@example.com', status: User::STATUS_ACTIVE,
                         password: ENV['PAT_TEST_PASSWORD'], password_confirmation: ENV['PAT_TEST_PASSWORD'])
    Member.create!(project: project, user: user, roles: [role])
    Issue.create!(project: project, tracker: Tracker.first, subject: 'PAT playwright test issue', author: user)

    valid = PersonalAccessToken.create!(user: user, name: 'pw-valid', expires_on: 30.days.from_now)

    expired = PersonalAccessToken.create!(user: user, name: 'pw-expired', expires_on: 30.days.from_now)
    expired_value = expired.value
    expired.update_column(:expires_on, 1.day.ago)

    scoped = PersonalAccessToken.create!(user: user, name: 'pw-scoped', expires_on: 30.days.from_now, scopes: 'view_issues')

    revoked = PersonalAccessToken.create!(user: user, name: 'pw-revoked', expires_on: 30.days.from_now)
    revoked_value = revoked.value
    revoked.destroy

    puts JSON.generate({
      project_id: project.identifier,
      valid_key: valid.value,
      expired_key: expired_value,
      scoped_key: scoped.value,
      revoked_key: revoked_value,
      legacy_api_key: user.api_key,
    })
  `;

  const output = execFileSync(
    'docker',
    ['compose', 'exec', '-T', '-e', 'PAT_TEST_PASSWORD=PlaywrightPat123!', 'redmine',
      'bundle', 'exec', 'rails', 'runner', script],
    { cwd: REPO_ROOT, encoding: 'utf8' },
  );

  const jsonLine = output.trim().split('\n').pop() ?? '';
  return JSON.parse(jsonLine) as Fixtures;
}

let fx: Fixtures;
let api: APIRequestContext;

test.beforeAll(async ({ playwright }) => {
  fx = setupFixtures();
  api = await playwright.request.newContext({ baseURL: 'http://localhost:3000' });
});

test.afterAll(async () => {
  await api.dispose();
});

test('valid PAT authenticates and can read', async () => {
  const res = await api.get(`/issues.json?project_id=${fx.project_id}&key=${fx.valid_key}`);
  expect(res.status()).toBe(200);
  const body = await res.json();
  expect(body.issues.length).toBeGreaterThan(0);
});

test('expired PAT is rejected', async () => {
  const res = await api.get(`/issues.json?project_id=${fx.project_id}&key=${fx.expired_key}`);
  expect(res.status()).toBe(401);
});

test('scoped PAT can do what its scope allows', async () => {
  const res = await api.get(`/issues.json?project_id=${fx.project_id}&key=${fx.scoped_key}`);
  expect(res.status()).toBe(200);
});

test('scoped PAT is denied what its scope excludes', async () => {
  const list = await api.get(`/issues.json?project_id=${fx.project_id}&key=${fx.scoped_key}`);
  const issueId = (await list.json()).issues[0].id;
  const res = await api.put(`/issues/${issueId}.json?key=${fx.scoped_key}`, {
    data: { issue: { subject: 'attempted edit outside scope' } },
  });
  expect(res.status()).toBe(403);
});

test('legacy API key still works unchanged', async () => {
  const res = await api.get(`/issues.json?project_id=${fx.project_id}&key=${fx.legacy_api_key}`);
  expect(res.status()).toBe(200);
});

test('revoked PAT is rejected immediately, no separate blacklist to go stale', async () => {
  const res = await api.get(`/issues.json?project_id=${fx.project_id}&key=${fx.revoked_key}`);
  expect(res.status()).toBe(401);
});
