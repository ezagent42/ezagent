// Record the Hello snapshot receipt → live World Kanban closeout proof.
// Required: DEMO_PASS. Optional: DEMO_ORIGIN, DEMO_OUTDIR, DEMO_USER.

const {chromium} = require("playwright")
const fs = require("fs")
const path = require("path")

const origin = process.env.DEMO_ORIGIN || "http://127.0.0.1:10052"
const out = process.env.DEMO_OUTDIR || "docs/e2e/2026-07-16/hello-kanban-product-closeout"
const email = process.env.DEMO_USER || "admin@ezagent.chat"
const password = process.env.DEMO_PASS
const instruction = `录屏验收：官网活动页交给 Kanban 跟进 ${Date.now()}`
const viewport = {width: 1280, height: 720}

if (!password) throw new Error("DEMO_PASS is required")

const pause = (page, ms = 1200) => page.waitForTimeout(ms)
const snap = (page, name) => page.screenshot({path: path.join(out, `${name}.png`), fullPage: true})

async function lockViewport(page) {
  await page.setViewportSize(viewport)
  const actual = await page.evaluate(() => ({width: window.innerWidth, height: window.innerHeight}))
  if (actual.width !== viewport.width || actual.height !== viewport.height) {
    throw new Error(`viewport drifted to ${actual.width}x${actual.height}`)
  }
}

async function videoContext(browser) {
  return browser.newContext({
    viewport,
    screen: viewport,
    deviceScaleFactor: 1,
    locale: "zh-CN",
    recordVideo: {dir: out, size: viewport},
  })
}

async function showHome(page) {
  if (!(await page.locator("#hello-product-entry").isVisible())) {
    await page.getByText("首页 · Home", {exact: true}).click()
  }
  await page.locator("#hello-product-entry").waitFor({state: "visible"})
}

async function redactTokenDelivery(page) {
  await page.route("**/login/token", async (route) => {
    const response = await route.fetch()
    const body = (await response.text()).replace(
      /(<code id="one-time-personal-access-token">)[\s\S]*?(<\/code>)/,
      "$1[REDACTED — one-time token hidden from recording]$2",
    )
    await route.fulfill({response, body})
  })
}

async function login(page, returnTo) {
  await page.goto(`${origin}/login?return_to=${encodeURIComponent(returnTo)}`, {waitUntil: "domcontentloaded"})
  await page.fill("#email", email)
  await page.fill("#password", password)
  await page.locator('button[type="submit"]').click()
  await waitForTokenDelivery(page)
  await page.click("#continue-after-token")
}

async function waitForTokenDelivery(page) {
  try {
    await page.waitForURL(/\/login\/token$/, {timeout: 30000})
  } catch (error) {
    const message = await page.locator("body").innerText().catch(() => "")
    throw new Error(`login did not reach token delivery (${page.url()}): ${message.slice(0, 500)}`, {cause: error})
  }
}

async function saveVideo(context, page, filename) {
  const video = page.video()
  await context.close()
  if (video) fs.renameSync(await video.path(), path.join(out, filename))
}

;(async () => {
  fs.mkdirSync(out, {recursive: true})
  for (const file of fs.readdirSync(out)) {
    if (/\.(webm|png)$/.test(file)) fs.rmSync(path.join(out, file), {force: true})
  }

  const browser = await chromium.launch({headless: true})

  // Recording A: honest snapshot → concrete live board → mutate → reload.
  const contextA = await videoContext(browser)
  const pageA = await contextA.newPage()
  await redactTokenDelivery(pageA)
  await pageA.goto(`${origin}/hello/fusion`, {waitUntil: "domcontentloaded"})
  await lockViewport(pageA)
  await showHome(pageA)
  await pageA.locator("#hello-product-entry").scrollIntoViewIfNeeded()
  await pause(pageA, 1600)
  await snap(pageA, "01-hello-entry")

  await pageA.locator('#hello-prompt-form input[name="instruction"]').fill(instruction)
  await pageA.locator("#hello-prompt-form").evaluate((form) => form.requestSubmit())
  await pageA.waitForURL(/\/login(?:\?|$)/, {timeout: 20000})
  await pageA.fill("#email", email)
  await pageA.fill("#password", password)
  await pageA.locator('button[type="submit"]').click()
  await waitForTokenDelivery(pageA)
  await pageA.click("#continue-after-token")
  await pageA.waitForURL(/\/hello\/fusion$/)
  await lockViewport(pageA)
  await showHome(pageA)
  await pageA.waitForSelector("#hello-published-board-status", {timeout: 30000})
  await pageA.locator("#hello-kanban-result").scrollIntoViewIfNeeded()
  await pause(pageA, 1800)
  await snap(pageA, "02-honest-snapshot-receipt")

  const liveHref = await pageA.locator(".hello-kanban-result-link:not(.is-secondary)").getAttribute("href")
  if (!liveHref || !liveHref.startsWith("/plugins/kanban/")) throw new Error("live World board link missing")

  await pageA.goto(`${origin}${liveHref}`, {waitUntil: "domcontentloaded"})
  await lockViewport(pageA)
  await pageA.waitForFunction((text) => document.body.innerText.includes(text), instruction, {timeout: 30000})
  await pause(pageA, 1600)
  await snap(pageA, "03-world-board-initial")

  await pageA.getByRole("button", {name: /认领/}).click()
  await pause(pageA, 1200)
  await pageA.locator("label", {hasText: "状态"}).locator("select").selectOption("doing")
  await pause(pageA, 1800)
  await snap(pageA, "04-world-board-mutated")

  await pageA.reload({waitUntil: "domcontentloaded"})
  await lockViewport(pageA)
  await pageA.waitForFunction((text) => document.body.innerText.includes(text), instruction, {timeout: 30000})
  await pageA.waitForFunction(() => document.body.innerText.includes("doing"), null, {timeout: 30000})
  await pause(pageA, 1600)
  await snap(pageA, "05-world-board-reread")

  await pageA.goto(`${origin}/hello/fusion`, {waitUntil: "domcontentloaded"})
  await lockViewport(pageA)
  await showHome(pageA)
  await pageA.waitForSelector("#hello-published-board-status")
  await pageA.locator("#hello-kanban-result").scrollIntoViewIfNeeded()
  await pause(pageA, 1400)
  await snap(pageA, "06-receipt-remains-snapshot")
  await saveVideo(contextA, pageA, "hello-kanban-live-board-reflux.webm")

  // Recording B: natural-language concierge navigation actually switches tabs.
  const contextB = await videoContext(browser)
  const pageB = await contextB.newPage()
  await redactTokenDelivery(pageB)
  await login(pageB, "/hello/fusion")
  await pageB.waitForURL(/\/hello\/fusion$/)
  await lockViewport(pageB)
  await showHome(pageB)
  await pageB.locator('#hello-prompt-form input[name="instruction"]').fill("看看团队")
  await pageB.locator("#hello-prompt-form").evaluate((form) => form.requestSubmit())
  await pageB.getByText("林懿伦", {exact: true}).first().waitFor({state: "visible", timeout: 60000})
  await pause(pageB, 2200)
  await snap(pageB, "07-concierge-team-navigation")
  await saveVideo(contextB, pageB, "hello-concierge-navigation.webm")

  await browser.close()
  process.stdout.write(JSON.stringify({out, instruction, files: fs.readdirSync(out).sort()}) + "\n")
})().catch((error) => {
  console.error(error)
  process.exit(1)
})
