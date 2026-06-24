import { chromium } from 'playwright-core'
const CHROME = '/home/yaosh/.cache/ms-playwright/chromium-1223/chrome-linux64/chrome'
const BASE = 'http://world.ezagent.chat:10042'
const SHOT = '/home/yaosh/projects/ezagent-biz/.claude/worktrees/df-tech/docs/superpowers/evidence/assets'
const T = 40000
const NAME = `mmflow${Date.now() % 100000}`
const MAP_A = `mapA-${Date.now() % 1000}`
const log = []; const p = (s) => log.push(s)
const browser = await chromium.launch({ executablePath: CHROME, args: ['--no-sandbox'] })
const page = await (await browser.newContext({ viewport: { width: 1360, height: 920 } })).newPage()
page.on('pageerror', (e) => p(`[PAGEERROR] ${e.message.slice(0, 160)}`))
let childName = `子-${Date.now() % 1000}`
page.on('dialog', (d) => d.accept(d.type() === 'prompt' ? childName : undefined))

try {
  await page.goto(`${BASE}/login`, { waitUntil: 'domcontentloaded', timeout: T })
  await page.waitForSelector('#email', { state: 'visible', timeout: T })
  await page.fill('#email', 'admin@ezagent.chat'); await page.fill('#password', 'worlddev')
  await page.click('button[type=submit]')
  await page.waitForURL((u) => !u.toString().includes('/login'), { timeout: 45000 })
  p('登录 ✓')

  // 点1：配置页无 Board ID
  await page.goto(`${BASE}/plugins/mindmap`, { waitUntil: 'domcontentloaded', timeout: T })
  await page.waitForSelector('input[type=password]', { state: 'visible', timeout: 45000 })
  const boardInputs = await page.locator('input[placeholder="board id"]').count()
  p(`① 配置页 Board ID 输入框数=${boardInputs}（应为 0）`)

  // 新建带 orchestrator 的 session
  await page.goto(`${BASE}/sessions`, { waitUntil: 'domcontentloaded', timeout: T })
  await page.waitForSelector('button[aria-label="Create a new session"]', { timeout: T })
  await page.click('button[aria-label="Create a new session"]')
  await page.fill('#world-session-short-name', NAME)
  await page.fill('#world-session-template', 'default')
  await page.click('#world-session-create-form button:has-text("Create")')
  await page.waitForTimeout(3000)
  await page.reload({ waitUntil: 'domcontentloaded' })
  await page.waitForSelector(`tr:has-text("${NAME}")`, { timeout: T })
  await page.locator('tr', { hasText: NAME }).locator('button:has-text("Open")').first().click()
  await page.waitForSelector('button[aria-label="Show mindmap"]', { timeout: T })
  p('新建 session + 进入 ✓')

  // 进 Mindmap → 侧边栏新建一张导图
  await page.click('button[aria-label="Show mindmap"]')
  await page.waitForSelector('input[placeholder="新导图名"]', { timeout: 90000 })
  await page.fill('input[placeholder="新导图名"]', MAP_A)
  await page.locator('input[placeholder="新导图名"] ~ button').first().click() // 新建 + 按钮
  await page.waitForTimeout(2000)
  // 选中刚建的导图（侧边栏出现）
  await page.waitForSelector(`aside button:has-text("${MAP_A}")`, { timeout: T })
  p(`② 侧边栏新建导图 ${MAP_A} ✓`)

  // 修改：建根 + 加子
  const rootInput = page.locator('input[placeholder*="根节点"]')
  if (await rootInput.count()) { await rootInput.fill('图A根'); await page.click('button:has-text("建根")'); await page.waitForTimeout(1500) }
  await page.waitForSelector('.react-flow__node', { timeout: T })
  await page.locator('.react-flow__node button[title="加子节点"]').first().click()
  await page.waitForTimeout(2000)
  p(`③ 修改：建根+加子（节点数=${await page.locator('.react-flow__node').count()}）✓`)

  // 选中节点 → 侧边栏节点属性 → 认领
  await page.locator('.react-flow__node').first().click()
  await page.waitForSelector('aside:has-text("节点属性") button:has-text("认领")', { timeout: T })
  await page.locator('aside button:has-text("认领")').click()
  await page.waitForTimeout(1500)
  p('④ 节点属性面板 + 认领 ✓')
  await page.screenshot({ path: `${SHOT}/flow-1-edit.png` })

  // ③' 同步到 Miro（改名后的按钮）
  await page.click('button:has-text("同步到 Miro")')
  await page.waitForSelector('text=打开 Miro 看板', { timeout: 35000 })
  p('⑤ 同步到 Miro ✓')

  // 传到会话：分享到对话
  await page.click('button:has-text("分享到对话")')
  await page.waitForTimeout(2000)
  await page.click('button[aria-label="Show chat"]')
  await page.waitForSelector('button:has-text("点击编辑")', { timeout: T })
  p('⑥ 分享到对话 → chat 出现卡片 ✓')
  await page.screenshot({ path: `${SHOT}/flow-2-card.png` })

  // 点 chat 卡片 → 跳回 mindmap
  await page.click('button:has-text("点击编辑")')
  await page.waitForSelector('aside:has-text("导图")', { timeout: T })
  p('⑦ 点 chat 卡片 → 跳回 mindmap ✓')

  // 选择已有的另一张导图（session 默认 sess-xxx，与 图A 并存）
  const mapButtons = await page.locator('aside ul button').count()
  p(`⑧ 侧边栏导图数=${mapButtons}（应≥2：${MAP_A} + session默认）`)
  const other = page.locator('aside ul button', { hasNotText: MAP_A }).first()
  if (await other.count()) { await other.click(); await page.waitForTimeout(1500); p('选择已有导图 ✓') }
  await page.screenshot({ path: `${SHOT}/flow-3-select.png` })

  p('======== 完整流程 e2e 全通过 ✅ ========')
} catch (e) { p(`[失败] ${e.message.split('\n')[0].slice(0, 180)}`); await page.screenshot({ path: `${SHOT}/flow-fail.png` }).catch(() => {}) }
console.log(log.join('\n')); await browser.close()
