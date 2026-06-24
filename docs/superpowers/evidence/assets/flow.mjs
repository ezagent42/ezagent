import { chromium } from 'playwright-core'
const CHROME = '/home/yaosh/.cache/ms-playwright/chromium-1223/chrome-linux64/chrome'
const BASE = 'http://world.ezagent.chat:10042'
const SHOT = '/home/yaosh/projects/ezagent-biz/.claude/worktrees/df-tech/docs/superpowers/evidence/assets'
const SESSION = 'session://system/default/mindmap'
const T = 60000
const log = []; const p = (s) => { log.push(s); }

// 07 流程 9 棒：真相源=mindmap 节点 content
const CHAIN = [
  { title: '战略定位', stage: 'positioning', content: '一页定位稿：价值主张=产品团队10分钟定版开发流程；交易公式=规范化开发→快速迭代' },
  { title: '北极星指标', stage: 'metric', content: '北极星=周闭环数≥20；drop阈值=帖7天阅读<500砍子树', metric: ['周闭环数', '20'] },
  { title: '痛点清单', stage: 'pain', content: '痛点1:开发完才补产品运营(P0)；痛点2:每天100+PR收束不到价值(P0)' },
  { title: '认领映射', stage: 'anchor', content: '岗位↔层映射:产品负责人→定位/锚定；运营→验证；研发→issue/测试/PR' },
  { title: '线框原型', stage: 'ux', content: '四条UX承诺:一图看全链/认领即问责/gate软门/drop反哺' },
  { title: '功能spec卡', stage: 'feature', content: '用户故事:作为研发按spec卡开issue\nGiven spec卡验收写全\nWhen 开issue\nThen 携带Gherkin\nICE=高' },
  { title: 'issue卡', stage: 'issue', content: '范围:9阶段链UI；不做:LLM agent；验收用例=spec卡Gherkin' },
  { title: '测试套件', stage: 'test', content: '测试=spec卡Gherkin写成用例；mix test 绿' },
  { title: 'PR', stage: 'pr', content: 'PR:只动spec卡范围；过gate清单' },
]
let pendingTitle = ''
const browser = await chromium.launch({ executablePath: CHROME, args: ['--no-sandbox'] })
const page = await (await browser.newContext({ viewport: { width: 1500, height: 1000 } })).newPage()
page.on('pageerror', (e) => p(`[PAGEERROR] ${e.message.slice(0, 140)}`))
page.on('dialog', (d) => {
  const m = d.message()
  if (m.includes('子节点')) d.accept(pendingTitle)
  else if (m.includes('指标名')) d.accept('周闭环数')
  else if (m.includes('目标值')) d.accept('20')
  else if (m.includes('PR')) d.accept('3')
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
const shot = async (name) => {
  // 画布布局已修(固定高、不滚走)，直接等 fit 落定后截图
  await page.waitForTimeout(900)
  await page.screenshot({ path: `${SHOT}/${name}.png` })
}
const addContent = async (name, body) => {
  await page.locator('aside button:has-text("加内容")').click()
  await page.fill('aside input[placeholder*="产物名"]', name)
  await page.fill('aside textarea', body)
  await page.locator('aside button:has-text("保存")').click()
  await page.waitForTimeout(800)
}
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
  if (!ready) throw new Error('mindmap 子视图未出现')
  await page.fill('input[placeholder="新导图名"]', `flow-${Date.now() % 10000}`)
  await page.locator('input[placeholder="新导图名"] ~ button').first().click()
  await page.waitForSelector('input[placeholder*="根节点"]', { timeout: T })
  p('登录+新导图 ✓')

  // ① 建根=定位 + 真相源内容
  await page.fill('input[placeholder*="根节点"]', CHAIN[0].title)
  await page.click('button:has-text("建根")')
  await page.waitForSelector('.react-flow__node', { timeout: T })
  await selectNode(CHAIN[0].title)
  await addContent('一页定位稿', CHAIN[0].content)
  p(`①棒[定位] 建根+真相源 ✓`)
  await shot(`flow-b1-${CHAIN[0].stage}`)

  // ②-⑨ 棒：加子→设stage→真相源内容(+指标)
  for (let i = 1; i < CHAIN.length; i++) {
    // 画布已稳，父节点选中做成强制（点不中就重试，不再静默容错→避免加到错父）
    await selectNode(CHAIN[i - 1].title)
    pendingTitle = CHAIN[i].title
    await page.locator('aside button:has-text("加子")').click()
    await page.waitForSelector(`.react-flow__node:has-text("${CHAIN[i].title}")`, { timeout: T })
    await page.waitForTimeout(700)
    await selectNode(CHAIN[i].title)
    await page.locator('aside select').nth(1).selectOption(CHAIN[i].stage)
    await page.waitForTimeout(900)
    await selectNode(CHAIN[i].title)
    await addContent(CHAIN[i].title + '稿', CHAIN[i].content)
    if (CHAIN[i].metric) { await page.locator('aside button:has-text("设指标")').click(); await page.waitForTimeout(800); await selectNode(CHAIN[i].title) }
    p(`${'①②③④⑤⑥⑦⑧⑨'[i]}棒[${CHAIN[i].stage}] 加子+stage+真相源${CHAIN[i].metric ? '+指标' : ''} ✓`)
    await shot(`flow-b${i + 1}-${CHAIN[i].stage}`)
  }
  await shot('flow-1-chain')
  p('==== 9 棒接力链 + 真相源全建 ✓ (flow-1-chain) ====')

  // ⑨ PR 棒：认领 → 登记 PR#3(需求摘要留言) → 同步(merged→done)
  await selectNode('PR')
  await page.click('aside button:has-text("认领")'); await page.waitForTimeout(1000)
  const reg = page.locator('aside button:has-text("登记 PR")'); await reg.scrollIntoViewIfNeeded(); await reg.click()
  await page.waitForSelector('aside a:has-text("打开")', { timeout: T })
  await page.click('button:has-text("同步 PR 状态")'); await page.waitForTimeout(4000)
  await selectNode('PR')
  const st = await page.locator('aside select').first().inputValue().catch(() => '?')
  p(`⑨棒[PR] 认领+登记PR#3(需求摘要留言)+同步→状态=${st}(应done) ${st === 'done' ? '✓' : '✗'}`)
  await shot('flow-2-pr-done')

  // ⑨→② 回收闭环：drop 功能子树(不达标)→反哺最近痛点
  await selectNode('功能spec卡')
  const drop = page.locator('aside button[title*="砍整个子树"]'); await drop.scrollIntoViewIfNeeded(); await drop.click()
  await page.waitForTimeout(1500)
  const featGone = (await page.locator('.react-flow__node').filter({ hasText: '功能spec卡' }).count()) === 0
  await selectNode('痛点清单')
  const painHasDrop = await page.locator('aside').filter({ hasText: 'drop:' }).count() > 0
  p(`drop 功能子树(不达标)→砍掉=${featGone} + 痛点反哺drop_record=${painHasDrop}`)
  await shot('flow-3-drop-feedback')

  p('======== 07 完整流程 e2e 走完 ========')
} catch (e) { p(`[失败] ${e.message.split('\n')[0].slice(0, 200)}`); await shot('flow-fail').catch(() => {}) }
console.log(log.join('\n')); await browser.close()
