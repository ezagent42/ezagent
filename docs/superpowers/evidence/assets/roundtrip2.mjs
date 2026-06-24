import { chromium } from 'playwright-core'
const CHROME = '/home/yaosh/.cache/ms-playwright/chromium-1223/chrome-linux64/chrome'
const BASE = 'http://world.ezagent.chat:10042'
const SHOT = '/home/yaosh/projects/ezagent-biz/.claude/worktrees/df-tech/docs/superpowers/evidence/assets'
const T = 25000
const NAME = `mmrt${Date.now() % 100000}`
const log = []; const p = (s) => log.push(s)
const browser = await chromium.launch({ executablePath: CHROME, args: ['--no-sandbox'] })
const page = await (await browser.newContext({ viewport: { width: 1320, height: 900 } })).newPage()
page.on('pageerror', (e) => p(`[PAGEERROR] ${e.message.slice(0, 160)}`))
try {
  await page.goto(`${BASE}/login`, { waitUntil: 'domcontentloaded', timeout: T })
  await page.waitForSelector('#email', { state: 'visible', timeout: T })
  await page.fill('#email', 'admin@ezagent.chat'); await page.fill('#password', 'worlddev')
  await page.click('button[type=submit]')
  await page.waitForURL((u) => !u.toString().includes('/login'), { timeout: 45000 })
  p('登录 ✓')

  // 新建带 orchestrator 的 session
  await page.goto(`${BASE}/sessions`, { waitUntil: 'domcontentloaded', timeout: T })
  await page.waitForSelector('button[aria-label="Create a new session"]', { timeout: T })
  await page.click('button[aria-label="Create a new session"]')
  await page.fill('#world-session-short-name', NAME)
  await page.fill('#world-session-template', 'default')
  await page.click('#world-session-create-form button:has-text("Create")')
  await page.waitForTimeout(3000)
  // 已知 React 刷新问题：建完表格不刷新，reload 后才出现
  await page.reload({ waitUntil: 'domcontentloaded' })
  await page.waitForSelector(`tr:has-text("${NAME}")`, { timeout: T })
  p(`新建 session ${NAME} ✓（reload 后出现）`)

  // 进入新 session
  await page.locator('tr', { hasText: NAME }).locator('button:has-text("Open")').first().click()
  await page.waitForSelector('button[aria-label="Show mindmap"]', { timeout: T })
  p('进入新 session ✓')

  // 控制实验：先普通发一条，确认这个 session 回送
  await page.click('button[aria-label="Show chat"]')
  const ta = page.locator('textarea').first()
  await ta.fill('echo-check')
  await page.click('button:has-text("Send")')
  await page.waitForSelector('text=echo-check', { timeout: T })
  p('✅ 新 session 会回送消息（chat 可用）')

  // mindmap 子视图 → 建根（新 board 空）→ 分享到对话
  await page.click('button[aria-label="Show mindmap"]')
  await page.waitForSelector('button:has-text("分享到对话")', { timeout: T })
  const rootInput = page.locator('input[placeholder*="根节点"]')
  if (await rootInput.count()) { await rootInput.fill('来回根'); await page.click('button:has-text("建根")'); await page.waitForTimeout(1500) }
  await page.click('button:has-text("分享到对话")')
  await page.waitForTimeout(2500)
  p('分享到对话 ✓')

  // 切 chat → 卡片出现
  await page.click('button[aria-label="Show chat"]')
  await page.waitForSelector('button:has-text("点击编辑")', { timeout: T })
  p('✅ chat 出现可点 mindmap 卡片')
  await page.screenshot({ path: `${SHOT}/rt-1-card.png` })

  // 点卡片 → 跳回 mindmap
  await page.click('button:has-text("点击编辑")')
  await page.waitForSelector('.react-flow, input[placeholder*="根节点"]', { timeout: T })
  await page.waitForSelector('button:has-text("分享到对话")', { timeout: T })
  p('✅ 点卡片 → 跳回 Mindmap 编辑视图')
  await page.screenshot({ path: `${SHOT}/rt-2-jumped.png` })

  p('======== chat↔mindmap 来回 e2e 全通过 ✅ ========')
} catch (e) { p(`[失败] ${e.message.split('\n')[0].slice(0, 180)}`); await page.screenshot({ path: `${SHOT}/rt-fail.png` }).catch(() => {}) }
console.log(log.join('\n')); await browser.close()
