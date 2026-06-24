import { chromium } from 'playwright-core'

const CHROME = '/home/yaosh/.cache/ms-playwright/chromium-1223/chrome-linux64/chrome'
const BASE = 'http://world.ezagent.chat:10042'
const SHOT = '/home/yaosh/projects/ezagent-biz/.claude/worktrees/df-tech/docs/superpowers/evidence/assets'
const SESSION = 'session://system/default/main'
const T = 20000
const log = []
const p = (s) => log.push(s)

const browser = await chromium.launch({ executablePath: CHROME, args: ['--no-sandbox'] })
const page = await (await browser.newContext({ viewport: { width: 1320, height: 860 } })).newPage()
page.on('pageerror', (e) => p(`[PAGEERROR] ${e.message.slice(0, 160)}`))

try {
  // 1) 登录
  await page.goto(`${BASE}/login`, { waitUntil: 'domcontentloaded', timeout: T })
  await page.fill('#email', 'admin@ezagent.chat')
  await page.fill('#password', 'worlddev')
  await Promise.all([page.waitForNavigation({ timeout: T }).catch(() => {}), page.click('button[type=submit]')])
  p(`登录后: ${page.url()}`)

  // 2) 进 seeded session 的会话视图
  await page.goto(`${BASE}/sessions?session=${encodeURIComponent(SESSION)}`, { waitUntil: 'domcontentloaded', timeout: T })
  await page.waitForSelector('button[aria-label="Show mindmap"]', { timeout: T })
  p('会话视图渲染 ✓（Chat/PTY/Mindmap tab 出现）')
  await page.screenshot({ path: `${SHOT}/e2e-session-1-tabs.png` })

  // 3) 点 Mindmap tab → 等子视图
  await page.click('button[aria-label="Show mindmap"]')
  await page.waitForTimeout(2500)
  await page.screenshot({ path: `${SHOT}/e2e-session-2-mindmap.png` })
  p(`mindmap 子视图: 思维导图标题=${await page.locator('text=思维导图').count()}`)

  // 4) 建根（若已有根则跳过）
  const rootInput = page.locator('input[placeholder*="根节点"]')
  if (await rootInput.count()) {
    await rootInput.fill('会话内产品骨架')
    await page.click('button:has-text("建根")')
    await page.waitForSelector('text=会话内产品骨架', { timeout: T })
    p('会话内建根 ✓')
  } else {
    p('已有根（复用 session board）')
  }

  // 5) 加子 + 认领
  await page.locator('button[title="加子节点"]').first().click()
  await page.fill('input[placeholder="子节点标题"]', '会话内子节点')
  await page.locator('button:has-text("加")').first().click()
  await page.waitForSelector('text=会话内子节点', { timeout: T })
  p('会话内加子 ✓')
  await page.locator('button[title="认领"]').first().click()
  await page.waitForSelector('text=@admin', { timeout: T })
  p('会话内认领 ✓')
  await page.screenshot({ path: `${SHOT}/e2e-session-3-edited.png` })

  // 6) 推送到 Miro
  await page.click('button:has-text("推送到 Miro")')
  await page.waitForSelector('text=打开 Miro 看板', { timeout: 30000 })
  p('会话内推 Miro ✓')
  await page.screenshot({ path: `${SHOT}/e2e-session-4-miro.png` })

  p('======== session 内 mindmap 全链路通过 ✅ ========')
} catch (e) {
  p(`[失败] ${e.message.split('\n')[0].slice(0, 200)}`)
  await page.screenshot({ path: `${SHOT}/e2e-session-fail.png` }).catch(() => {})
}
console.log(log.join('\n'))
await browser.close()
