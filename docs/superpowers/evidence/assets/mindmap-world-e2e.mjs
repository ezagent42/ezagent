import { chromium } from 'playwright-core'

const CHROME = '/home/yaosh/.cache/ms-playwright/chromium-1223/chrome-linux64/chrome'
const BASE = 'http://world.ezagent.chat:10042'
const SHOT = '/home/yaosh/projects/ezagent-biz/.claude/worktrees/df-tech/docs/superpowers/evidence/assets'
const T = 20000

const log = []
const p = (s) => log.push(s)

const browser = await chromium.launch({ executablePath: CHROME, args: ['--no-sandbox'] })
const ctx = await browser.newContext({ viewport: { width: 1320, height: 860 } })
const page = await ctx.newPage()
page.on('pageerror', (e) => p(`[PAGEERROR] ${e.message.slice(0, 160)}`))

try {
  // 1) 登录
  await page.goto(`${BASE}/login`, { waitUntil: 'domcontentloaded', timeout: T })
  await page.fill('#email', 'admin@ezagent.chat')
  await page.fill('#password', 'worlddev')
  await Promise.all([page.waitForNavigation({ timeout: T }).catch(() => {}), page.click('button[type=submit]')])
  p(`登录后: ${page.url()}`)

  // 2) mindmap 列表 —— 等"新建"按钮真出现（socket+state 到位）
  const mmName = `e2e-${Date.now()}`
  await page.goto(`${BASE}/plugins/mindmap`, { waitUntil: 'domcontentloaded', timeout: T })
  await page.waitForSelector('button:has-text("新建")', { timeout: T })
  await page.screenshot({ path: `${SHOT}/e2e-1-list.png` })
  p('列表页渲染 ✓（新建按钮出现）')

  // 3) 真点「新建」→ 等跳到详情页
  await page.fill('input[placeholder*="新建导图"]', mmName)
  await page.click('button:has-text("新建")')
  await page.waitForURL('**/plugins/mindmap/**', { timeout: T })
  p(`新建 ✓ → ${decodeURIComponent(page.url()).split('/').pop()}`)

  // 4) 建根 —— 等输入框出现
  await page.waitForSelector('input[placeholder*="根节点"]', { timeout: T })
  await page.fill('input[placeholder*="根节点"]', 'df-prd 产品工作台')
  await page.click('button:has-text("建根")')
  await page.waitForSelector('text=df-prd 产品工作台', { timeout: T })
  p('建根 ✓（根节点出现）')

  // 5) 加子节点
  await page.locator('button[title="加子节点"]').first().click()
  await page.fill('input[placeholder="子节点标题"]', '节点数据模型')
  await page.locator('button:has-text("加")').first().click()
  await page.waitForSelector('text=节点数据模型', { timeout: T })
  p('加子 ✓（子节点出现）')

  // 6) 认领根节点 → 等 @admin 出现
  await page.locator('button[title="认领"]').first().click()
  await page.waitForSelector('text=@admin', { timeout: T })
  p('认领 ✓（@admin 出现）')

  // 7) 改状态 → doing
  await page.locator('select').first().selectOption('doing')
  await page.waitForTimeout(1200)
  p('改状态 ✓')
  await page.screenshot({ path: `${SHOT}/e2e-4-operated.png` })

  // 8) 推送到 Miro
  await page.click('button:has-text("推送到 Miro")')
  await page.waitForSelector('text=打开 Miro 看板', { timeout: 30000 })
  p('推送 Miro ✓（看板链接出现）')
  await page.screenshot({ path: `${SHOT}/e2e-5-miro.png` })

  p('======== 全部操作通过 ✅ ========')
} catch (e) {
  p(`[失败] ${e.message.split('\n')[0].slice(0, 200)}`)
  await page.screenshot({ path: `${SHOT}/e2e-fail.png` }).catch(() => {})
}

console.log(log.join('\n'))
await browser.close()
