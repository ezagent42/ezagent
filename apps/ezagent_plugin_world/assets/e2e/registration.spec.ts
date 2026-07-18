import {expect, test} from "@playwright/test"

test.skip(!process.env.EZAGENT_E2E_BASE_URL, "requires a live Phoenix endpoint")

test.describe("self-service registration boundary", () => {
  test("closed registration offers access request and invite paths", async ({page}) => {
    await page.goto("/register")

    await expect(page.getByRole("heading", {name: "Sign up"})).toBeVisible()
    await expect(page.locator("#registration-request-form")).toBeVisible()
    await expect(page.locator("#invite-registration-form")).toBeVisible()

    await page.locator("#request_email").fill(`browser-${Date.now()}@example.com`)
    await page.getByRole("button", {name: "Submit request"}).click()

    await expect(page.getByRole("heading", {name: "Request received"})).toBeVisible()
  })

  test("invalid invite deep links fail closed with an actionable message", async ({page}) => {
    await page.goto("/register?invite=not-a-real-invite")

    await expect(page.getByText("Registration is currently closed.")).toBeVisible()
    await expect(page.getByText("That invite code is not valid.")).toBeVisible()
  })
})
