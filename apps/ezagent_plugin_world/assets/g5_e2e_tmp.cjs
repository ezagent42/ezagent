/* G5 E2E scenario B (async agent error → per-viewer card → founder notify).
 * Run: cd apps/ezagent_plugin_world/assets && node /tmp/g5_e2e.js
 */
const {chromium} = require("playwright")
const fs = require("fs")

const BASE = process.env.BASE || "http://127.0.0.1:10052"
const SESSION_ENC = encodeURIComponent("session://system/default/g5-test")
const OUT = "/tmp/g5_shots"
fs.mkdirSync(OUT, {recursive: true})

const log = (...a) => console.log("[e2e]", ...a)

async function login(browser, email, password) {
  const ctx = await browser.newContext({viewport: {width: 1440, height: 900}})
  const page = await ctx.newPage()
  page.on("pageerror", (e) => log("PAGEERROR", email, String(e)))
  await page.goto(BASE + "/login")
  await page.fill("#email", email)
  await page.fill("#password", password)
  await Promise.all([page.waitForNavigation(), page.click('button[type="submit"]')])
  log("logged in", email, "→", page.url())
  return page
}

async function openSession(page) {
  await page.goto(BASE + "/sessions?session=" + SESSION_ENC)
  await page.waitForSelector("textarea", {timeout: 30000})
  await page.waitForTimeout(800)
}

;(async () => {
  const browser = await chromium.launch()

  // Founder online FIRST so the live notification reaches their LV.
  const founder = await login(browser, "g5-founder@e2e.local", "e2etest123")
  await openSession(founder)

  // B1: member sends → async {:no_api_key} → inline Layer 2 card
  const member = await login(browser, "g5-member@e2e.local", "e2etest123")
  await openSession(member)
  await member.fill("textarea", "hello")
  await member.press("textarea", "Enter")
  log("member sent hello; waiting for inline error card…")
  await member.waitForSelector("[data-world-message-error-card]", {timeout: 60000})
  await member.waitForTimeout(600)
  const memberCard = await member.locator("[data-world-message-error-card]").last().innerText()
  log("member card:", JSON.stringify(memberCard))
  await member.screenshot({path: OUT + "/B1-member-layer2-card.png"})

  // B2: member clicks 发送提醒
  const notifyBtn = member
    .locator("[data-world-message-error-card] [data-world-dispatch-error-notify]")
    .last()
  await notifyBtn.click()
  await member.waitForTimeout(1200)
  await member.screenshot({path: OUT + "/B2-member-notify-clicked.png"})
  log("notify clicked")

  // B3: founder side — the notification event lands in their LV world_state.
  await founder.waitForTimeout(1500)
  const founderHtml = await founder.content()
  log("founder DOM contains error_fix_request:", founderHtml.includes("error_fix_request"))
  await founder.screenshot({path: OUT + "/B3-founder-after-notify.png"})

  // Founder (non-admin) also views the same message → Layer 2 for them too.
  const founderCards = await founder.locator("[data-world-message-error-card]").count()
  log("founder visible inline cards:", founderCards)

  // A: ADMIN viewer of the SAME durable message → Layer 1 card (fix link)
  const admin = await login(browser, "admin@ezagent.chat", "worlddev")
  await openSession(admin)
  await admin.waitForSelector("[data-world-message-error-card]", {timeout: 30000})
  const adminCard = await admin.locator("[data-world-message-error-card]").last().innerText()
  const fixLinks = await admin.locator("[data-world-message-error-card] a").count()
  log("admin card:", JSON.stringify(adminCard), "fix links:", fixLinks)
  await admin.screenshot({path: OUT + "/A1-admin-layer1-card.png"})

  // Success-path sanity: admin agent still absent key, so instead verify plain
  // messages render unchanged: member's own "hello" bubble is present.
  const helloVisible = await member.locator("text=hello").first().isVisible()
  log("member sees own hello bubble:", helloVisible)

  await browser.close()
  log("DONE")
})().catch((e) => {
  console.error("[e2e] FAILED", e)
  process.exit(1)
})
