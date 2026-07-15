// Record the website Hello -> Kanban published-read product path.
//
// Required env:
//   DEMO_PASS       local admin password (never written to evidence)
// Optional env:
//   DEMO_USER       defaults to admin@ezagent.chat
//   DEMO_ORIGIN     defaults to http://127.0.0.1:10042
//   DEMO_OUTDIR     evidence output directory

// The one-time PAT is redacted in the intercepted token-delivery HTML before
// Chromium renders it. The recording and screenshots therefore contain no
// credential or share-token material.

const { chromium } = require("playwright")
const fs = require("fs")
const path = require("path")

const origin = process.env.DEMO_ORIGIN || "http://127.0.0.1:10042"
const out = process.env.DEMO_OUTDIR || "./demo-out/hello-kanban-published-read"
const email = process.env.DEMO_USER || "admin@ezagent.chat"
const password = process.env.DEMO_PASS
const width = 1440
const height = 1000
const instruction = `录屏验收：Hello 官网派活到 Kanban，并发布只读同步看板 ${Date.now()}`

if (!password) throw new Error("DEMO_PASS is required")

const pause = (page, ms = 1200) => page.waitForTimeout(ms)

async function snap(page, name) {
  await page.screenshot({ path: path.join(out, `${name}.png`) })
}

async function redactPatDelivery(page) {
  await page.route("**/login/token", async (route) => {
    const response = await route.fetch()
    const body = await response.text()
    const redacted = body.replace(
      /(<code id="one-time-personal-access-token">)[\s\S]*?(<\/code>)/,
      "$1[REDACTED — one-time token hidden from recording]$2",
    )
    await route.fulfill({ response, body: redacted })
  })
}

;(async () => {
  fs.mkdirSync(out, { recursive: true })
  for (const file of fs.readdirSync(out)) {
    if (/\.(webm|png)$/.test(file)) fs.rmSync(path.join(out, file), { force: true })
  }

  const browser = await chromium.launch({ headless: true })
  const context = await browser.newContext({
    viewport: { width, height },
    locale: "zh-CN",
    recordVideo: { dir: out, size: { width, height } },
  })
  const page = await context.newPage()
  await redactPatDelivery(page)

  // 1. Public website product entry and explicit Hello delegation CTA.
  await page.goto(`${origin}/hello/fusion`, { waitUntil: "domcontentloaded" })
  await page.waitForSelector("#hello-product-entry", { state: "visible" })
  await page.locator("#hello-product-entry").scrollIntoViewIfNeeded()
  await pause(page, 1800)
  await snap(page, "01-hello-product-entry")

  await page.locator("#hello-prompt-form input[name=instruction]").fill(instruction)
  await pause(page, 1000)
  await page.locator("#hello-prompt-form").evaluate((form) => form.requestSubmit())

  // 2. Login continuation. The PAT delivery page is response-redacted above.
  await page.waitForURL(/\/login(?:\?|$)/, { timeout: 20000 })
  await page.fill("#email", email)
  await page.fill("#password", password)
  await pause(page, 900)
  await page.locator('button[type="submit"]').click()
  await page.waitForURL(/\/login\/token$/, { timeout: 30000 })
  await page.waitForSelector("#continue-after-token")
  await pause(page, 700)
  await page.click("#continue-after-token")

  // 3. Real Hello receipt: original board URI + publication revision + boundary.
  await page.waitForURL(/\/hello\/fusion$/, { timeout: 30000 })
  await page.waitForSelector("#hello-published-board-status", { timeout: 30000 })
  await page.waitForFunction((text) => document.body.innerText.includes(text), instruction, {
    timeout: 30000,
  })
  await page.locator("#hello-kanban-result").scrollIntoViewIfNeeded()
  await pause(page, 2200)
  await snap(page, "02-published-read-receipt")

  const receiveHref = await page.locator(".hello-kanban-result-link").getAttribute("href")
  if (!receiveHref || !receiveHref.startsWith("/socialware/kanban/receive?token=")) {
    throw new Error("published read link was not rendered")
  }

  // 4. Receive in Session 2. Navigate programmatically so the signed token is
  // never visible in the browser chrome captured by the compositor.
  await page.goto(`${origin}${receiveHref}`, { waitUntil: "domcontentloaded" })
  await page.waitForURL(/\/sessions\?session=/, { timeout: 30000 })
  await page.waitForFunction(() => document.body.innerText.includes("看板已加入你的工作区（只读）"), null, {
    timeout: 20000,
  })
  await pause(page, 1800)
  await snap(page, "03-session2-readonly-received")

  // 5. Keep the receiving session's explicit Kanban tab and readonly flash
  // visible long enough for a human reviewer. The mutation denial and shared
  // tree read are asserted by the integration test companion rather than by
  // pretending that absence of a button proves authorization.
  await pause(page, 2500)

  const video = page.video()
  await context.close()
  if (video) fs.renameSync(await video.path(), path.join(out, "hello-kanban-published-read.webm"))
  await browser.close()

  process.stdout.write(
    JSON.stringify({
      video: path.join(out, "hello-kanban-published-read.webm"),
      screenshots: fs.readdirSync(out).filter((file) => file.endsWith(".png")).sort(),
    }) + "\n",
  )
})().catch((error) => {
  console.error(error)
  process.exit(1)
})
