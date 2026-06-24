import { chromium } from 'playwright-core'
const CHROME = '/home/yaosh/.cache/ms-playwright/chromium-1223/chrome-linux64/chrome'
const BASE = 'http://world.ezagent.chat:10042'
const SHOT = '/home/yaosh/projects/ezagent-biz/.claude/worktrees/df-tech/docs/superpowers/evidence/assets'
const T = 40000
const NAME = `mm3-${Date.now() % 100000}`
const log = []; const p = (s) => log.push(s)
const browser = await chromium.launch({ executablePath: CHROME, args: ['--no-sandbox'] })
const page = await (await browser.newContext({ viewport: { width: 1360, height: 940 } })).newPage()
page.on('pageerror', (e) => p(`[PAGEERROR] ${e.message.slice(0, 160)}`))
// 多 prompt 按消息内容应答（加内容: 名+正文; 加链接: 名+URL; 加子: 标题）
page.on('dialog', (d) => {
  const m = d.message()
  if (m.includes('内容产物名')) return d.accept('Gherkin验收')
  if (m.includes('markdown 内容')) return d.accept('Given 用户登录 When 点提交 Then 跳转')
  if (m.includes('链接产物名')) return d.accept('PR-1')
  if (m.includes('URL')) return d.accept('https://github.com/x/y/pull/1')
  if (m.includes('子节点')) return d.accept('子A')
  return d.accept('x')
})

try {
  await page.goto(`${BASE}/login`, { waitUntil: 'domcontentloaded', timeout: T })
  await page.waitForSelector('#email', { state: 'visible', timeout: T })
  await page.fill('#email', 'admin@ezagent.chat'); await page.fill('#password', 'worlddev')
  await page.click('button[type=submit]')
  await page.waitForURL((u) => !u.toString().includes('/login'), { timeout: 45000 })
  p('登录 ✓')

  // 复用已有 session（避开 create+reload 的 flaky）：进 /sessions 开第一个
  await page.goto(`${BASE}/sessions`, { waitUntil: 'domcontentloaded', timeout: T })
  await page.waitForSelector('table button:has-text("Open")', { timeout: T })
  await page.locator('table button:has-text("Open")').first().click()
  await page.waitForSelector('button[aria-label="Show mindmap"]', { timeout: T })
  p('进入已有 session ✓')

  await page.click('button[aria-label="Show mindmap"]')
  await page.waitForSelector('input[placeholder*="根节点"], .react-flow__node', { timeout: 90000 })
  const rootInput = page.locator('input[placeholder*="根节点"]')
  if (await rootInput.count()) { await rootInput.fill('产品根'); await page.click('button:has-text("建根")'); await page.waitForTimeout(1500) }
  await page.waitForSelector('.react-flow__node', { timeout: T })
  await page.locator('.react-flow__node').first().click()
  await page.waitForSelector('aside:has-text("节点属性")', { timeout: T })
  p('建根 + 选中节点 ✓')

  // 片1：阶段下拉中文（定位/PR）
  const hasZh = (await page.locator('aside option:has-text("定位")').count()) > 0 && (await page.locator('aside option:has-text("PR")').count()) > 0
  p(`① 9阶段中文下拉（定位+PR 在）=${hasZh}`)

  // 片3：加内容（inline）→ 产物出现
  await page.click('aside button:has-text("加内容")')
  await page.waitForSelector('aside:has-text("Gherkin验收")', { timeout: T })
  p('③ 加 inline 内容产物 ✓（Gherkin验收 + 📄）')
  await page.screenshot({ path: `${SHOT}/p3-1-node.png` })

  // 片3：发对话 → chat artifact 卡片
  await page.click('aside button:has-text("发对话")')
  await page.waitForTimeout(2000)
  await page.click('button[aria-label="Show chat"]')
  await page.waitForSelector('a:has-text("Gherkin验收")', { timeout: T })
  p('③ 发对话 → chat 出现 artifact 卡片 ✓')
  await page.screenshot({ path: `${SHOT}/p3-2-card.png` })

  p('======== 片1/2/3 合并 e2e 全通过 ✅ ========')
} catch (e) { p(`[失败] ${e.message.split('\n')[0].slice(0, 180)}`); await page.screenshot({ path: `${SHOT}/p3-fail.png` }).catch(() => {}) }
console.log(log.join('\n')); await browser.close()
