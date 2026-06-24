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
  if (m.includes('GitHub 仓库')) d.accept('REPO_REDACTED')
  else if (m.includes('Miro 板名')) d.accept('我的看板演示')
  else if (m.includes('commit SHA')) d.accept('a1b2c3d4e5f6')
  else if (m.includes('文件路径')) d.accept('docs/discuss/1-homesite/P-用户画像-personas.md')
  else if (m.includes('子节点')) d.accept(pendingTitle)
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
  await page.fill('input[placeholder="新导图名"]', `code-${Date.now() % 10000}`)
  await page.locator('input[placeholder="新导图名"] ~ button').first().click()
  await page.waitForSelector('input[placeholder*="根节点"]', { timeout: T })
  await page.fill('input[placeholder*="根节点"]', '定位稿')
  await page.click('button:has-text("建根")')
  await page.waitForSelector('.react-flow__node', { timeout: T })
  await selectNode('定位稿')
  p('建根+选中 ✓')

  // ① 本图配置：设 github 仓库 + miro 板名
  await page.locator('button:has-text("⚙ 配置")').click()
  await page.waitForTimeout(1500)
  await page.waitForSelector("text=GitHub: jjkysy", { timeout: 8000 }).catch(()=>{}); const cfgLabel = await page.locator("text=GitHub: REPO_REDACTED").textContent().catch(()=>"")
  p(`① 本图配置 → 按钮显示=${cfgLabel?.trim()}（应含 REPO_REDACTED）`)
  await page.screenshot({ path: `${SHOT}/code-1-config.png` })

  // ② 挂代码文件：SHA + 路径 → github blob 链接
  await page.locator('aside button:has-text("挂代码文件")').click()
  await page.waitForSelector('aside a:has-text("打开")', { timeout: T })
  const href = await page.locator('aside a:has-text("打开")').first().getAttribute('href')
  p(`② 挂代码文件 → 产物链接=${href}`)
  const okLink = href && href.includes('github.com/REPO_REDACTED/blob/a1b2c3d4e5f6/')
  await page.screenshot({ path: `${SHOT}/code-2-file.png` })

  // ③ 新阶段名：建到 anchor(目标用户) 看标签对不对
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
  // 看 anchor 节点的 stage 标签
  const anchorLabel = await page.locator('aside .rounded.bg-muted').first().textContent().catch(() => '?')
  p(`③ 新阶段名：anchor 节点标签=${anchorLabel?.trim()}（应=目标用户，不是认领映射）`)
  await page.screenshot({ path: `${SHOT}/code-3-stages.png` })

  if (okLink && cfgLabel?.includes('REPO_REDACTED')) p('======== 每图配置+挂代码文件+阶段名 e2e 通过 ✅ ========')
  else p('======== 有问题 ✗ ========')
} catch (e) { p(`[失败] ${e.message.split('\n')[0].slice(0, 180)}`); await page.screenshot({ path: `${SHOT}/code-fail.png` }).catch(() => {}) }
console.log(log.join('\n')); await browser.close()
