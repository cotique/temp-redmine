import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { ADMIN_LOGIN, ADMIN_DEV_PASSWORD } from './tests/utils';

// Repo root, resolved relative to THIS file rather than the process's current
// working directory - `cwd: '..'` would silently break whenever `playwright
// test` is invoked from anywhere other than this playwright/ directory (e.g.
// from the repo root), since a relative cwd resolves against the caller's
// cwd, not the script's own location.
const REPO_ROOT = path.resolve(__dirname, '..');

// Pins the dev DB's admin password to a known value before any test runs, via
// the running docker-compose container - not via the UI. Redmine forces a
// password change on the admin account's first login, and once that's done
// once (by anyone, including a previous test run) the "default" admin/admin
// credential no longer works. Doing this out-of-band makes login
// deterministic regardless of what state the persistent dev DB volume is in.
export default function globalSetup(): void {
  const script =
    `u = User.find_by_login('${ADMIN_LOGIN}'); ` +
    `u.password = ENV['DEV_ADMIN_PASSWORD']; ` +
    `u.password_confirmation = ENV['DEV_ADMIN_PASSWORD']; ` +
    `u.must_change_passwd = false; ` +
    `u.save!(validate: false)`;

  execFileSync(
    'docker',
    ['compose', 'exec', '-T', '-e', `DEV_ADMIN_PASSWORD=${ADMIN_DEV_PASSWORD}`, 'redmine',
      'bundle', 'exec', 'rails', 'runner', script],
    { cwd: REPO_ROOT, stdio: 'inherit' },
  );
}
