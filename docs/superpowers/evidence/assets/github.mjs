import { chromium } from 'playwright-core'
const CHROME = '/home/yaosh/.cache/ms-playwright/chromium-1223/chrome-linux64/chrome'
const BASE = 'http://world.ezagent.chat:10042'
const SHOT = '/home/yaosh/projects/ezagent-biz/.claude/worktrees/df-tech/docs/superpowers/evidence/assets'
const SESSION = 'session://system/default/mindmap'
const TOKEN = 'github_pat_REDACTED'
const REPO = 'jjkysy/test-ezagent'
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

  // ① 配置 GitHub 凭证（配置页，不写死，同 Miro）
  await page.goto(`${BASE}/plugins/mindmap`, { waitUntil: 'domcontentloaded', timeout: T })
  await page.waitForSelector('input[placeholder="粘贴 GitHub PAT"]', { state: 'visible', timeout: 45000 })
  await page.fill('input[placeholder="粘贴 GitHub PAT"]', TOKEN)
  await page.fill('input[placeholder*="jjkysy/test-ezagent"]', REPO)
  await page.locator('button:has-text("保存凭证")').nth(1).click()
  await page.waitForSelector(`text=${REPO}`, { timeout: T })
  p('① 配置 GitHub 凭证 → 已配置 ✓ ' + REPO)
  await page.screenshot({ path: `${SHOT}/gh-1-config.png` })

  // ② 进 session → 建根 → 选中
  await page.goto(`${BASE}/sessions?session=${encodeURIComponent(SESSION)}`, { waitUntil: 'domcontentloaded', timeout: T })
  await page.waitForSelector('button[aria-label="Show mindmap"]', { timeout: T })
  let ready = false
  for (let i = 0; i < 15 && !ready; i++) {
    await page.click('button[aria-label="Show mindmap"]').catch(() => {})
    await page.waitForTimeout(2000)
    ready = (await page.locator('input[placeholder="新导图名"]').count()) > 0
  }
  if (!ready) throw new Error('mindmap 子视图未出现')
  await page.fill('input[placeholder="新导图名"]', `gh-${Date.now() % 10000}`)
  await page.locator('input[placeholder="新导图名"] ~ button').first().click()
  await page.waitForSelector('input[placeholder*="根节点"]', { timeout: T })
  await page.fill('input[placeholder*="根节点"]', 'GitHub出站测试节点')
  await page.click('button:has-text("建根")')
  await page.waitForSelector('.react-flow__node', { timeout: T })
  await page.locator('.react-flow__node').first().click({ force: true })
  await page.waitForSelector('aside .font-medium:has-text("GitHub出站测试节点")', { timeout: T })
  p('② 建根 + 选中 ✓')

  // ③ 出站到 GitHub → 真建 issue → issue 回挂到节点（产物出现 + 打开链接）
  const ghBtn = page.locator('aside button:has-text("出站 GitHub")')
  await ghBtn.scrollIntoViewIfNeeded()
  await ghBtn.click()
  await page.waitForSelector('aside a:has-text("打开")', { timeout: T })
  const issueHref = await page.locator('aside a:has-text("打开")').first().getAttribute('href')
  p(`③ 出站 GitHub → 节点挂上 issue 产物，打开链接=${issueHref}`)
  await page.screenshot({ path: `${SHOT}/gh-2-issue.png` })

  p('======== 片6 GitHub 出站 e2e 全通过 ✅ ========')
} catch (e) { p(`[失败] ${e.message.split('\n')[0].slice(0, 180)}`); await page.screenshot({ path: `${SHOT}/gh-fail.png` }).catch(() => {}) }
console.log(log.join('\n')); await browser.close()
