import { chromium } from 'playwright-core'
const CHROME = '/home/yaosh/.cache/ms-playwright/chromium-1223/chrome-linux64/chrome'
const BASE = 'http://world.ezagent.chat:10042'
const SHOT = '/home/yaosh/projects/ezagent-biz/.claude/worktrees/df-tech/docs/superpowers/evidence/assets'
const SESSION = 'session://system/default/mindmap'
const PR = '3' // 上面 diag 造的已 merged PR
const T = 70000
const log = []; const p = (s) => log.push(s)
const browser = await chromium.launch({ executablePath: CHROME, args: ['--no-sandbox'] })
const page = await (await browser.newContext({ viewport: { width: 1360, height: 940 } })).newPage()
page.on('pageerror', (e) => p(`[PAGEERROR] ${e.message.slice(0, 160)}`))
page.on('dialog', (d) => d.accept(PR)) // 登记 PR 的 prompt
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
  await page.fill('input[placeholder="新导图名"]', `ghw-${Date.now() % 10000}`)
  await page.locator('input[placeholder="新导图名"] ~ button').first().click()
  await page.waitForSelector('input[placeholder*="根节点"]', { timeout: T })
  await page.fill('input[placeholder*="根节点"]', 'PR闭环测试节点')
  await page.click('button:has-text("建根")')
  await page.waitForSelector('.react-flow__node', { timeout: T })
  await page.locator('.react-flow__node').first().click({ force: true })
  await page.waitForSelector('aside .font-medium:has-text("PR闭环测试节点")', { timeout: T })
  p('建根 + 选中 ✓')

  // ① 认领（set_status 需先认领）
  await page.click('aside button:has-text("认领")')
  await page.waitForTimeout(1500)
  p('① 认领 ✓')

  // ② 登记 PR #3 → 出站「产品需求摘要」留言 + PR 回挂到节点
  const regBtn = page.locator('aside button:has-text("登记 PR")')
  await regBtn.scrollIntoViewIfNeeded()
  await regBtn.click()
  await page.waitForSelector('aside a:has-text("打开")', { timeout: T })
  const prHref = await page.locator('aside a:has-text("打开")').first().getAttribute('href')
  p(`② 登记 PR #${PR} → 产品需求摘要留言已发 + PR 回挂，链接=${prHref}`)
  await page.screenshot({ path: `${SHOT}/ghworker-1-register.png` })

  // ③ 同步 PR 状态 → 轮询 PR#3 = merged → 自动 set_status done
  await page.click('button:has-text("同步 PR 状态")')
  await page.waitForTimeout(4000)
  const statusVal = await page.locator('aside select').first().inputValue().catch(() => '?')
  p(`③ 同步 PR 状态 → 节点状态=${statusVal}（应=done，因 PR#${PR} 已 merged）`)
  await page.screenshot({ path: `${SHOT}/ghworker-2-synced.png` })
  if (statusVal !== 'done') throw new Error('状态未自动推进到 done，实际=' + statusVal)

  p('======== GitHub PR 闭环 worker e2e 全通过 ✅ ========')
} catch (e) { p(`[失败] ${e.message.split('\n')[0].slice(0, 180)}`); await page.screenshot({ path: `${SHOT}/ghworker-fail.png` }).catch(() => {}) }
console.log(log.join('\n')); await browser.close()
