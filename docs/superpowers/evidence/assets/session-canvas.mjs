import { chromium } from 'playwright-core'

const CHROME = '/home/yaosh/.cache/ms-playwright/chromium-1223/chrome-linux64/chrome'
const BASE = 'http://world.ezagent.chat:10042'
const SHOT = '/home/yaosh/projects/ezagent-biz/.claude/worktrees/df-tech/docs/superpowers/evidence/assets'
const SESSION = 'session://system/default/main'
const T = 25000
const log = []
const p = (s) => log.push(s)

const browser = await chromium.launch({ executablePath: CHROME, args: ['--no-sandbox'] })
const page = await (await browser.newContext({ viewport: { width: 1320, height: 900 } })).newPage()
page.on('pageerror', (e) => p(`[PAGEERROR] ${e.message.slice(0, 160)}`))
// 自动应答 window.prompt（加子/改名用）——子节点标题
let childName = `画布子-${Date.now() % 1000}`
page.on('dialog', (d) => d.accept(d.type() === 'prompt' ? childName : undefined))

try {
  await page.goto(`${BASE}/login`, { waitUntil: 'domcontentloaded', timeout: T })
  await page.waitForSelector('#email', { state: 'visible', timeout: T })
  await page.fill('#email', 'admin@ezagent.chat')
  await page.fill('#password', 'worlddev')
  await page.click('button[type=submit]')
  await page.waitForURL((u) => !u.toString().includes('/login'), { timeout: 45000 })
  p(`登录 ✓ → ${page.url()}`)

  await page.goto(`${BASE}/sessions?session=${encodeURIComponent(SESSION)}`, { waitUntil: 'domcontentloaded', timeout: T })
  await page.waitForSelector('button[aria-label="Show mindmap"]', { timeout: T })
  await page.click('button[aria-label="Show mindmap"]')
  await page.waitForSelector('button:has-text("推送到 Miro")', { timeout: T })
  p('进 Mindmap 子视图 ✓')

  // 若无根先建根
  const rootInput = page.locator('input[placeholder*="根节点"]')
  if (await rootInput.count()) {
    await rootInput.fill('画布根节点')
    await page.click('button:has-text("建根")')
  }

  // react-flow 画布 + 节点渲染
  await page.waitForSelector('.react-flow', { timeout: T })
  await page.waitForSelector('.react-flow__node', { timeout: T })
  const nodeCount = await page.locator('.react-flow__node').count()
  p(`✅ react-flow 视觉画布渲染，节点数=${nodeCount}`)
  await page.screenshot({ path: `${SHOT}/canvas-1-tree.png` })

  // 加子（点节点上的 + → prompt 自动应答）
  await page.locator('.react-flow__node button[title="加子节点"]').first().click()
  await page.waitForFunction((n) => document.querySelectorAll('.react-flow__node').length > n, nodeCount, { timeout: T })
  p(`画布加子 ✓（节点数 ${nodeCount}→${await page.locator('.react-flow__node').count()}）`)

  // 选中一个节点 → 工具栏 → 认领
  await page.locator('.react-flow__node').first().click()
  await page.waitForSelector('text=选中：', { timeout: T })
  p('选中节点 → 工具栏出现 ✓')
  await page.locator('button[title="认领"]').first().click()
  await page.waitForTimeout(1500)
  await page.screenshot({ path: `${SHOT}/canvas-2-edited.png` })
  p('画布认领 ✓')

  // 推 Miro
  await page.click('button:has-text("推送到 Miro")')
  await page.waitForSelector('text=打开 Miro 看板', { timeout: 35000 })
  p('画布推 Miro ✓')
  await page.screenshot({ path: `${SHOT}/canvas-3-miro.png` })

  p('======== 视觉树(react-flow)e2e 全通过 ✅ ========')
} catch (e) {
  p(`[失败] ${e.message.split('\n')[0].slice(0, 200)}`)
  await page.screenshot({ path: `${SHOT}/canvas-fail.png` }).catch(() => {})
}
console.log(log.join('\n'))
await browser.close()
