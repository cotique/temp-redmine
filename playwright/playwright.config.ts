import { defineConfig, devices } from '@playwright/test';

// UI verification against the local Redmine dev server started via
// `docker compose up -d` at the repo root (docker-compose.yml / docker/dev).
// This is a standalone verification harness, not the Rails app's own test
// suite (which still uses Capybara/Selenium under test/system).
export default defineConfig({
  testDir: './tests',
  globalSetup: './global-setup.ts',
  fullyParallel: false,
  retries: 0,
  reporter: [['list']],
  use: {
    baseURL: process.env.REDMINE_BASE_URL || 'http://localhost:3000',
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
  },
  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'] },
    },
  ],
});
