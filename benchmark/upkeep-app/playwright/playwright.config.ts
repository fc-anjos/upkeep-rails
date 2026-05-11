import { defineConfig, devices } from "@playwright/test";

const baseURL = process.env.UPKEEP_APP_URL ?? "http://localhost:3010";

export default defineConfig({
  testDir: "./tests",
  // Fail fast: no retries in CI — flaky is broken.
  retries: 0,
  // Single worker keeps the test server clean; M3 reactivity tests are
  // stateful (they mutate the DB and assert DOM delivery).
  workers: 1,
  timeout: 30_000,
  expect: {
    // DOM update delivery should be fast; 10s is generous for local dev.
    timeout: 10_000,
  },
  reporter: [["list"], ["html", { open: "never" }]],
  use: {
    baseURL,
    // Capture artifacts on failure for post-mortem debugging.
    screenshot: "only-on-failure",
    trace: "on-first-retry",
    video: "off",
  },
  projects: [
    {
      name: "chromium",
      use: { ...devices["Desktop Chrome"] },
    },
  ],
});
