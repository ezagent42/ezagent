import { chromium } from 'playwright-core'
const CHROME = '/home/yaosh/.cache/ms-playwright/chromium-1223/chrome-linux64/chrome'
const BASE = 'http://world.ezagent.chat:10042'
const SHOT = '/home/yaosh/projects/ezagent-biz/.claude/worktrees/df-tech/docs/superpowers/evidence/assets'
const SESSION = 'session://system/default/mindmap'
const T = 60000
const log = []; const p = (s) => log.push(s)
let pendingTitle = ''
const browser = await chromium.launch({ executablePath: CHROME, args: ['--no-sandbox'] })
const page = await (await browser.newContext({ viewport: { width: 1500, height: 1000 } })).newPage()
page.on('pageerror', (e) => p(`[PAGEERROR] ${e.message.slice(0, 140)}`))
page.on('dialog', (d) => {
  const m = d.message()
  if (m.includes('子节点')) d.accept(pendingTitle)
  else if (m.includes('drop')) d.accept('指标不达标：7天阅读<500')
  else d.accept('x')
})
const selectNode = async (title) => {
  for (let a = 0; a < 6; a++) {
    try {
      if (a > 0) await page.locator('.react-flow__controls-fitview').click({ timeout: 2000 }).catch(() => {})
      await page.waitForTimeout(400)
      await page.locator('.react-flow__node').filter({ hasText: title }).first().click({ force: true })
      await page.waitForSelector(`aside .font-medium:has-text("${title}")`, { timeout: 6000 })
      return
    } catch { await page.waitForTimeout(900) }
  }
  throw new Error('selectNode 点不中: ' + title)
}
try {
  await page.goto(`${BASE}/login`, { waitUntil: 'domcontentloaded', timeout: T })
  await page.waitForSelector('#email', { timeout: T })
  await page.fill('#email', 'admin@ezagent.chat'); await page.fill('#password', 'worlddev')
  await page.click('button[type=submit]')
  await page.waitForURL((u) => !u.toString().includes('/login'), { timeout: 45000 })
  await page.goto(`${BASE}/sessions?session=${encodeURIComponent(SESSION)}`, { waitUntil: 'domcontentloaded', timeout: T })
  await page.waitForSelector('button[aria-label="Show kanban"]', { timeout: T })
  let ready = false
  for (let i = 0; i < 15 && !ready; i++) { await page.click('button[aria-label="Show kanban"]').catch(() => {}); await page.waitForTimeout(1800); ready = (await page.locator('input[placeholder="新导图名"]').count()) > 0 }
  await page.fill('input[placeholder="新导图名"]', `drop-${Date.now() % 10000}`)
  await page.locator('input[placeholder="新导图名"] ~ button').first().click()
  await page.waitForSelector('input[placeholder*="根节点"]', { timeout: T })
  await page.fill('input[placeholder*="根节点"]', '定位稿')
  await page.click('button:has-text("建根")')
  await page.waitForSelector('.react-flow__node', { timeout: T })
  await selectNode('定位稿')
  // 建 定位→北极星→痛点→目标用户
  for (const [t, stage] of [['北极星指标', 'metric'], ['痛点清单', 'pain'], ['目标用户卡', 'anchor']]) {
    pendingTitle = t
    await page.locator('aside button:has-text("加子")').click()
    await page.waitForSelector(`.react-flow__node:has-text("${t}")`, { timeout: T })
    await page.waitForTimeout(600)
    await selectNode(t)
    await page.locator('aside select').nth(1).selectOption(stage)
    await page.waitForTimeout(700)
    await selectNode(t)
  }
  p('建 定位→北极星→痛点→目标用户 ✓')

  // drop 目标用户 → 最近痛点祖先(痛点清单)记一笔
  await selectNode('目标用户卡')
  const drop = page.locator('aside button[title*="砍整个子树"]')
  await drop.scrollIntoViewIfNeeded(); await drop.click()
  await page.waitForTimeout(1500)
  const gone = (await page.locator('.react-flow__node').filter({ hasText: '目标用户卡' }).count()) === 0
  // drop 历史 = 图级别(侧栏 section)，不挂某个节点。随便选个节点都该看得到。
  await page.waitForTimeout(1000)
  const histSection = await page.locator('aside:has-text("drop 历史")').count()
  const histText = await page.locator('aside li:has-text("目标用户卡")').first().textContent().catch(() => '')
  p(`drop 目标用户→砍掉=${gone} ; 侧栏 drop 历史 section=${histSection > 0 ? '有' : '无'}`)
  p(`drop 历史条目: ${histText?.trim().slice(0, 90)}`)
  await page.screenshot({ path: `${SHOT}/drop-history.png` })
  if (gone && histSection > 0 && histText.includes('目标用户卡')) p('======== drop 历史(图级别) e2e 通过 ✅ ========')
  else p('======== drop 历史有问题(可能要重启 server 让 behavior 生效) ✗ ========')
} catch (e) { p(`[失败] ${e.message.split('\n')[0].slice(0, 180)}`); await page.screenshot({ path: `${SHOT}/drop-history-fail.png` }).catch(() => {}) }
console.log(log.join('\n')); await browser.close()
