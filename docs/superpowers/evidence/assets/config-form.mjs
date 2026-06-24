import { chromium } from 'playwright-core'

const CHROME = '/home/yaosh/.cache/ms-playwright/chromium-1223/chrome-linux64/chrome'
const BASE = 'http://world.ezagent.chat:10042'
const SHOT = '/home/yaosh/projects/ezagent-biz/.claude/worktrees/df-tech/docs/superpowers/evidence/assets'
const T = 25000
const log = []
const p = (s) => log.push(s)

const browser = await chromium.launch({ executablePath: CHROME, args: ['--no-sandbox'] })
const page = await (await browser.newContext({ viewport: { width: 1320, height: 860 } })).newPage()
page.on('pageerror', (e) => p(`[PAGEERROR] ${e.message.slice(0, 160)}`))

try {
  await page.goto(`${BASE}/login`, { waitUntil: 'domcontentloaded', timeout: T })
  await page.waitForSelector('#email', { state: 'visible', timeout: T })
  await page.fill('#email', 'admin@ezagent.chat')
  await page.fill('#password', 'worlddev')
  await Promise.all([page.waitForNavigation({ timeout: T }).catch(() => {}), page.click('button[type=submit]')])
  p(`登录 ✓`)

  await page.goto(`${BASE}/plugins/mindmap`, { waitUntil: 'domcontentloaded', timeout: T })
  await page.waitForSelector('input[type=password]', { state: 'visible', timeout: 45000 })
  p('配置页 ✓（Miro 凭证表单出现）')
  await page.screenshot({ path: `${SHOT}/cred-1-form.png` })

  await page.fill('input[type=password]', 'e2e-test-token-DO-NOT-USE')
  await page.fill('input[placeholder="board id"]', 'e2e-test-board')
  await page.click('button:has-text("保存凭证")')
  await page.waitForSelector('text=· ok', { timeout: T })
  p('保存凭证 ✓（状态 ok）')
  await page.screenshot({ path: `${SHOT}/cred-2-saved.png` })

  p('======== 凭证配置 e2e 通过 ✅ ========')
} catch (e) {
  p(`[失败] ${e.message.split('\n')[0].slice(0, 200)}`)
  await page.screenshot({ path: `${SHOT}/cred-fail.png` }).catch(() => {})
}
console.log(log.join('\n'))
await browser.close()
