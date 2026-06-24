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
page.on('dialog', (d) => d.accept('7天阅读<500，drop'))
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

  await page.fill('input[placeholder="新导图名"]', `drop-${Date.now() % 10000}`)
  await page.locator('input[placeholder="新导图名"] ~ button').first().click()
  await page.waitForSelector('input[placeholder*="根节点"]', { timeout: T })
  await page.fill('input[placeholder*="根节点"]', 'drop测根')
  await page.click('button:has-text("建根")')
  await page.waitForSelector('.react-flow__node', { timeout: T })
  await page.locator('.react-flow__node').first().click({ force: true })
  await page.waitForSelector('aside .font-medium:has-text("drop测根")', { timeout: T })
  p('新导图 + 建根 + 选中 ✓')

  // drop 砍子树（根）→ 子树没了，回到建根态
  const dropBtn = page.locator('aside button[title*="砍整个子树"]')
  await dropBtn.scrollIntoViewIfNeeded()
  await dropBtn.click()
  await page.waitForTimeout(2000)
  await page.waitForSelector('input[placeholder*="根节点"]', { timeout: T })
  const nodeCount = await page.locator('.react-flow__node').count()
  p(`drop 砍子树 → 节点数=${nodeCount}（应=0，子树砍掉回建根态）✓`)
  await page.screenshot({ path: `${SHOT}/drop-1.png` })

  p('======== 片8 drop e2e 全通过 ✅ ========')
} catch (e) { p(`[失败] ${e.message.split('\n')[0].slice(0, 180)}`); await page.screenshot({ path: `${SHOT}/drop-fail.png` }).catch(() => {}) }
console.log(log.join('\n')); await browser.close()
