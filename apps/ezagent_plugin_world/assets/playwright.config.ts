import {defineConfig, devices} from "@playwright/test"

// Some developer/runner environments inject an HTTP proxy whose NO_PROXY
// wildcard is not understood by Playwright's readiness client. Keep the
// localhost harness out of that proxy so a proxy 400 cannot masquerade as a
// ready web server.
process.env.NO_PROXY = `127.0.0.1,localhost,${process.env.NO_PROXY || ""}`
process.env.no_proxy = process.env.NO_PROXY

const liveBaseURL = process.env.EZAGENT_E2E_BASE_URL

export default defineConfig({
  testDir: "./e2e",
  fullyParallel: false,
  forbidOnly: Boolean(process.env.CI),
  retries: 0,
  workers: 1,
  reporter: process.env.CI ? "github" : "list",
  use: {
    baseURL: liveBaseURL || "http://127.0.0.1:4178",
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
    ...devices["Desktop Chrome"],
  },
  webServer: liveBaseURL
    ? undefined
    : {
        command: "node e2e/serve.mjs",
        url: "http://127.0.0.1:4178",
        reuseExistingServer: false,
        stdout: "pipe",
        stderr: "pipe",
        timeout: 15_000,
      },
  timeout: 15_000,
  expect: {timeout: 5_000},
})
