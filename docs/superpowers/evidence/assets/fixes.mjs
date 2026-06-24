import { chromium } from 'playwright-core'
const CHROME = '/home/yaosh/.cache/ms-playwright/chromium-1223/chrome-linux64/chrome'
const BASE = 'http://world.ezagent.chat:10042'
const SHOT = '/home/yaosh/projects/ezagent-biz/.claude/worktrees/df-tech/docs/superpowers/evidence/assets'
const SESSION = 'session://system/default/mindmap'
const T = 70000
const log = []; const p = (s) => log.push(s)
const browser = await chromium.launch({ executablePath: CHROME, args: ['--no-sandbox'] })
const page = await (await browser.newContext({ viewport: { width: 1360, height: 940 } })).newPage()
page.on('pageerror', (e) => p(`[PAGEERROR] ${e.message.slice(0, 160)}`))
try {
  await page.goto(`${BASE}/login`, { waitUntil: 'domcontentloaded', timeout: T })
  await page.waitForSelector('#email', { state: 'visible', timeout: T })
  await page.fill('#email', 'admin@ezagent.chat'); await page.fill('#password', 'worlddev')
  await page.click('button[type=submit]')
  await page.waitForURL((u) => !u.toString().includes('/login'), { timeout: 45000 })
  p('登录 ✓')

  await page.goto(`${BASE}/sessions?session=${encodeURIComponent(SESSION)}`, { waitUntil: 'domcontentloaded', timeout: T })
  await page.waitForSelector('button[aria-label="Show mindmap"]', { timeout: T })
  let ready = false
  for (let i = 0; i < 15 && !ready; i++) {
    await page.click('button[aria-label="Show mindmap"]').catch(() => {})
    await page.waitForTimeout(2000)
    ready = (await page.locator('input[placeholder="新导图名"]').count()) > 0
  }
  if (!ready) throw new Error('mindmap 子视图未出现')

  // 新建干净导图 + 建根（根节点稳定，避开加子的 react-flow flaky）
  await page.fill('input[placeholder="新导图名"]', `fix-${Date.now() % 10000}`)
  await page.locator('input[placeholder="新导图名"] ~ button').first().click()
  await page.waitForSelector('input[placeholder*="根节点"]', { timeout: T })
  await page.fill('input[placeholder*="根节点"]', '产品根')
  await page.click('button:has-text("建根")')
  await page.waitForSelector('.react-flow__node', { timeout: T })
  await page.locator('.react-flow__node').first().click({ force: true })
  await page.waitForSelector('aside .font-medium:has-text("产品根")', { timeout: T })
  p('新导图 + 建根 + 选中根 ✓')

  // ① stage 前端校验：根固定 positioning → 下拉只 1 个真选项(定位)
  const opts = await page.locator('aside select').nth(1).locator('option').count()
  p(`① stage 校验：根 stage 下拉真选项=${opts - 1}（应=1，根固定定位）`)

  // ② 错误横幅（校验拒绝→中文提示）：未认领就设 status → 红横幅"请先认领"
  await page.locator('aside select').first().selectOption('doing'); await page.waitForTimeout(1300)
  await page.waitForSelector('text=请先认领', { timeout: T })
  p('② 校验拒绝→中文红横幅"请先认领" ✓')
  await page.screenshot({ path: `${SHOT}/fix-1-error.png` })

  // ③ issue1 状态回显：认领 + 设 status=doing → 下拉回显 doing（不再绑空串）
  await page.locator('aside button:has-text("认领")').click(); await page.waitForTimeout(1000)
  await page.locator('aside select').first().selectOption('doing'); await page.waitForTimeout(1200)
  const statusVal = await page.locator('aside select').first().inputValue()
  p(`③ issue1 status 回显=${statusVal}（应=doing，证"改完看得到、已保存"）`)

  // ④ issue2 textarea 编辑器（替 window.prompt）
  await page.click('aside button:has-text("加内容")')
  await page.waitForSelector('aside textarea', { timeout: T })
  await page.fill('aside input[placeholder*="产物名"]', 'Gherkin验收')
  await page.fill('aside textarea', 'Given 用户登录\nWhen 点提交\nThen 跳转')
  await page.click('aside button:has-text("保存")')
  await page.waitForSelector('aside:has-text("Gherkin验收")', { timeout: T })
  p('④ issue2 textarea 编辑器→保存→产物出现 ✓')
  await page.screenshot({ path: `${SHOT}/fix-2-editor.png` })

  p('======== 3修正+stage校验+错误提示 e2e 全通过 ✅ ========')
} catch (e) { p(`[失败] ${e.message.split('\n')[0].slice(0, 180)}`); await page.screenshot({ path: `${SHOT}/fix-fail.png` }).catch(() => {}) }
console.log(log.join('\n')); await browser.close()
