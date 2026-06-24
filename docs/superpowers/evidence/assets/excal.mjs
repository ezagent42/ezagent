import { chromium } from 'playwright-core'
const CHROME = '/home/yaosh/.cache/ms-playwright/chromium-1223/chrome-linux64/chrome'
const BASE = 'http://world.ezagent.chat:10042'
const SHOT = '/home/yaosh/projects/ezagent-biz/.claude/worktrees/df-tech/docs/superpowers/evidence/assets'
const SESSION = 'session://system/default/mindmap'
const T = 60000
const log = []; const p = (s) => log.push(s)
const browser = await chromium.launch({ executablePath: CHROME, args: ['--no-sandbox'] })
const page = await (await browser.newContext({ viewport: { width: 1500, height: 1000 } })).newPage()
page.on('pageerror', (e) => p(`[PAGEERROR] ${e.message.slice(0, 160)}`))
try {
  await page.goto(`${BASE}/login`, { waitUntil: 'domcontentloaded', timeout: T })
  await page.waitForSelector('#email', { timeout: T })
  await page.fill('#email', 'admin@ezagent.chat'); await page.fill('#password', 'worlddev')
  await page.click('button[type=submit]')
  await page.waitForURL((u) => !u.toString().includes('/login'), { timeout: 45000 })
  await page.goto(`${BASE}/sessions?session=${encodeURIComponent(SESSION)}`, { waitUntil: 'domcontentloaded', timeout: T })
  await page.waitForSelector('button[aria-label="Show mindmap"]', { timeout: T })
  let ready = false
  for (let i = 0; i < 15 && !ready; i++) { await page.click('button[aria-label="Show mindmap"]').catch(() => {}); await page.waitForTimeout(1800); ready = (await page.locator('input[placeholder="新导图名"]').count()) > 0 }
  await page.fill('input[placeholder="新导图名"]', `excal-${Date.now() % 10000}`)
  await page.locator('input[placeholder="新导图名"] ~ button').first().click()
  await page.waitForSelector('input[placeholder*="根节点"]', { timeout: T })
  await page.fill('input[placeholder*="根节点"]', '画图测试节点')
  await page.click('button:has-text("建根")')
  await page.waitForSelector('.react-flow__node', { timeout: T })
  await page.locator('.react-flow__node').first().click({ force: true })
  await page.waitForSelector('aside .font-medium:has-text("画图测试节点")', { timeout: T })
  p('建根+选中 ✓')

  // 打开 excalidraw 画板
  await page.locator('aside button:has-text("画图")').click()
  await page.waitForSelector('.excalidraw', { timeout: T })
  await page.waitForTimeout(2500)
  // 量画板尺寸——验证不是塌成 0 高度
  const box = await page.locator('.excalidraw').boundingBox()
  p(`画板尺寸: ${Math.round(box?.width)}x${Math.round(box?.height)}（高度>400 = 没塌）`)
  await page.screenshot({ path: `${SHOT}/excal-1-editor.png` })

  // 在画板上画一笔（拖一条线，产生一个 element）
  const cx = box.x + box.width / 2, cy = box.y + box.height / 2
  await page.mouse.move(cx - 100, cy - 50)
  await page.mouse.down(); await page.mouse.move(cx + 100, cy + 50, { steps: 8 }); await page.mouse.up()
  await page.waitForTimeout(800)
  await page.screenshot({ path: `${SHOT}/excal-2-drawn.png` })

  // 保存到节点
  await page.locator('button:has-text("保存到节点")').click()
  await page.waitForTimeout(1500)
  // 画板关闭 + 节点出现 线框图 产物 + 看图按钮
  const closed = (await page.locator('.excalidraw').count()) === 0
  await page.locator('.react-flow__node').first().click({ force: true })
  const hasSeeBtn = (await page.locator('aside button:has-text("看图")').count()) > 0
  p(`保存: 画板关闭=${closed} + 节点产物有'看图'按钮=${hasSeeBtn}`)
  await page.screenshot({ path: `${SHOT}/excal-3-saved.png` })

  if (box?.height > 400 && hasSeeBtn) p('======== excalidraw 画板 e2e 通过 ✅ ========')
  else p('======== excalidraw 还有问题 ✗ ========')
} catch (e) { p(`[失败] ${e.message.split('\n')[0].slice(0, 180)}`); await page.screenshot({ path: `${SHOT}/excal-fail.png` }).catch(() => {}) }
console.log(log.join('\n')); await browser.close()
