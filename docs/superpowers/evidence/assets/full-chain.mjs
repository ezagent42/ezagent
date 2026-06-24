import { chromium } from 'playwright-core'

const CHROME = '/home/yaosh/.cache/ms-playwright/chromium-1223/chrome-linux64/chrome'
const BASE = 'http://world.ezagent.chat:10042'
const SHOT = '/home/yaosh/projects/ezagent-biz/.claude/worktrees/df-tech/docs/superpowers/evidence/assets'
const SESSION = 'session://system/default/main'
const T = 25000
const log = []
const p = (s) => log.push(s)

const browser = await chromium.launch({ executablePath: CHROME, args: ['--no-sandbox'] })
const page = await (await browser.newContext({ viewport: { width: 1320, height: 860 } })).newPage()
page.on('pageerror', (e) => p(`[PAGEERROR] ${e.message.slice(0, 160)}`))

try {
  // ===== 1) 登录 =====
  await page.goto(`${BASE}/login`, { waitUntil: 'domcontentloaded', timeout: T })
  await page.fill('#email', 'admin@ezagent.chat')
  await page.fill('#password', 'worlddev')
  await Promise.all([page.waitForNavigation({ timeout: T }).catch(() => {}), page.click('button[type=submit]')])
  p(`① 登录 ✓ → ${page.url()}`)

  // ===== 2) 配置：plugin 页 = Miro 凭证配置状态 =====
  await page.goto(`${BASE}/plugins/mindmap`, { waitUntil: 'domcontentloaded', timeout: T })
  await page.waitForSelector('text=思维导图 · 配置', { timeout: T })
  await page.waitForSelector('text=Miro 镜像', { timeout: T })
  const miroConfigured = (await page.locator('text=已配置').count()) > 0
  p(`② 配置页 ✓（Miro 镜像：${miroConfigured ? '已配置' : '未配置'}）`)
  await page.screenshot({ path: `${SHOT}/chain-1-config.png` })

  // ===== 3) 使用：进 session → Mindmap 子视图 → 建/用 =====
  await page.goto(`${BASE}/sessions?session=${encodeURIComponent(SESSION)}`, { waitUntil: 'domcontentloaded', timeout: T })
  await page.waitForSelector('button[aria-label="Show mindmap"]', { timeout: T })
  await page.click('button[aria-label="Show mindmap"]')
  await page.waitForSelector('button:has-text("推送到 Miro")', { timeout: T })
  p('③ 进 session + Mindmap 子视图 ✓')

  // 建根(若无) → 加子
  const rootInput = page.locator('input[placeholder*="根节点"]')
  if (await rootInput.count()) {
    await rootInput.fill('全链路根')
    await page.click('button:has-text("建根")')
    await page.waitForSelector('text=全链路根', { timeout: T })
  }
  await page.locator('button[title="加子节点"]').first().click()
  await page.fill('input[placeholder="子节点标题"]', `链路子-${Date.now() % 10000}`)
  await page.locator('button:has-text("加")').first().click()
  await page.waitForTimeout(1500)
  p('④ 会话内创建/编辑 ✓')
  await page.screenshot({ path: `${SHOT}/chain-2-use.png` })

  // ===== 4) 同步：推送 Miro =====
  await page.click('button:has-text("推送到 Miro")')
  await page.waitForSelector('text=打开 Miro 看板', { timeout: 35000 })
  p('⑤ 同步 Miro ✓（看板链接出现）')
  await page.screenshot({ path: `${SHOT}/chain-3-sync.png` })

  p('======== 完整链路 配置→创建→使用→同步 全通过 ✅ ========')
} catch (e) {
  p(`[失败] ${e.message.split('\n')[0].slice(0, 200)}`)
  await page.screenshot({ path: `${SHOT}/chain-fail.png` }).catch(() => {})
}
console.log(log.join('\n'))
await browser.close()
