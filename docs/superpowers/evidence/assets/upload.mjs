import { chromium } from 'playwright-core'
const CHROME = '/home/yaosh/.cache/ms-playwright/chromium-1223/chrome-linux64/chrome'
const BASE = 'http://world.ezagent.chat:10042'
const SHOT = '/home/yaosh/projects/ezagent-biz/.claude/worktrees/df-tech/docs/superpowers/evidence/assets'
const SESSION = 'session://system/default/mindmap'
const FILE = '/tmp/test-upload.txt'
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
  await page.fill('input[placeholder="新导图名"]', `up-${Date.now() % 10000}`)
  await page.locator('input[placeholder="新导图名"] ~ button').first().click()
  await page.waitForSelector('input[placeholder*="根节点"]', { timeout: T })
  await page.fill('input[placeholder*="根节点"]', '文件上传测试节点')
  await page.click('button:has-text("建根")')
  await page.waitForSelector('.react-flow__node', { timeout: T })
  await page.locator('.react-flow__node').first().click({ force: true })
  await page.waitForSelector('aside .font-medium:has-text("文件上传测试节点")', { timeout: T })
  p('建根 + 选中 ✓')

  // 上传文件 → 节点挂上 file 产物（带下载 href /uploads/download?token=）
  await page.locator('aside input[type=file]').setInputFiles(FILE)
  await page.waitForSelector('aside a:has-text("打开")', { timeout: T })
  const href = await page.locator('aside a:has-text("打开")').first().getAttribute('href')
  p(`上传文件 → 节点挂上 file 产物，下载链接=${href}`)
  if (!href || !href.includes('/uploads/download?token=')) throw new Error('下载 href 不对: ' + href)
  await page.screenshot({ path: `${SHOT}/upload-1.png` })

  p('======== 文件上传 e2e 全通过 ✅ ========')
} catch (e) { p(`[失败] ${e.message.split('\n')[0].slice(0, 180)}`); await page.screenshot({ path: `${SHOT}/upload-fail.png` }).catch(() => {}) }
console.log(log.join('\n')); await browser.close()
