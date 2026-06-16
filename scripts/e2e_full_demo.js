/**
 * AutoService Admin — Full E2E Demo Recorder
 *
 * Records a complete walkthrough of all admin functions:
 * 1. Master Dashboard — tenant overview
 * 2. Tenant Create — onboard new tenant
 * 3. Soul Edit — edit customer soul template
 * 4. Slots Edit — edit YAML slot values
 * 5. Skill Create — create new skill file
 * 6. KB Entry Add — add knowledge base entry
 * 7. CR Publish — publish change request
 * 8. Operator Console — CS session list
 */

const { chromium } = require('playwright');
const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');

const BASE_URL = 'http://localhost:10042';
const RECORDING_DIR = path.join(__dirname, 'e2e_recordings');
const WS = 'demo-acme';
const ADMIN_WS = 'system';

const TEST_TENANT = 'demo-' + Date.now().toString(36);

async function sleep(ms) {
  return new Promise(resolve => setTimeout(resolve, ms));
}

async function startServer() {
  console.log('[server] Starting Phoenix server...');
  const server = spawn('mix', ['phx.server'], {
    cwd: path.join(__dirname, '..'),
    env: { ...process.env, MIX_ENV: 'dev' },
    stdio: ['ignore', 'pipe', 'pipe']
  });

  for (let i = 0; i < 180; i++) {
    try {
      const resp = await fetch(`${BASE_URL}/login`);
      if (resp.status === 200 || resp.status === 302) {
        console.log('[server] Ready');
        await sleep(3000);
        return server;
      }
    } catch (e) {}
    if (i % 15 === 0 && i > 0) console.log(`[server] waiting... (${i}s)`);
    await sleep(1000);
  }
  throw new Error('Server timeout');
}

async function gotoAuth(page, path) {
  const url = path.includes('?') ? `${BASE_URL}${path}` : `${BASE_URL}${path}`;
  await page.goto(url, { waitUntil: 'networkidle', timeout: 20000 });
  await page.waitForSelector('[data-phx-main]', { timeout: 15000 }).catch(() => {});
  await sleep(1500);
  return page;
}

async function screenshot(page, name) {
  const p = path.join(RECORDING_DIR, name);
  await page.screenshot({ path: p, fullPage: true });
  console.log(`  📸 ${name}`);
}

async function main() {
  if (!fs.existsSync(RECORDING_DIR)) fs.mkdirSync(RECORDING_DIR, { recursive: true });

  let server, browser;
  try {
    server = await startServer();
    browser = await chromium.launch({ headless: true });
    const context = await browser.newContext({
      viewport: { width: 1440, height: 900 },
      recordVideo: { dir: RECORDING_DIR, size: { width: 1440, height: 900 } }
    });
    const page = await context.newPage();

    // ===================================================================
    // 1. Master Dashboard
    // ===================================================================
    console.log('\n=== 1. Master Dashboard ===');
    await gotoAuth(page, `/admin/autoservice?as=admin&workspace=${ADMIN_WS}`);
    await screenshot(page, '01-master-dashboard.png');

    // ===================================================================
    // 2. Tenant Onboard (create new tenant)
    // ===================================================================
    console.log('\n=== 2. Tenant Onboard ===');
    await gotoAuth(page, `/admin/autoservice/tenants/new?as=admin&workspace=${ADMIN_WS}`);
    await screenshot(page, '02a-tenant-onboard-step1.png');

    // Fill Step 1: Tenant ID + Brand Name
    const tidInput = page.locator('input[name="tid"]');
    const brandInput = page.locator('input[name="brand_name"]');
    if (await tidInput.isVisible()) {
      await tidInput.fill(TEST_TENANT);
      if (await brandInput.isVisible()) await brandInput.fill('Demo租户');
      await page.locator('button', { hasText: /Next|下一步|继续/ }).click();
      await sleep(1500);
      await screenshot(page, '02b-tenant-onboard-step2.png');
    }

    // Step 2: Admin Account
    const adminNameInput = page.locator('input[name="admin_handle"]');
    if (await adminNameInput.isVisible()) {
      await adminNameInput.fill('demo-admin');
      await page.locator('button', { hasText: /Next|下一步|继续/ }).click();
      await sleep(1500);
      await screenshot(page, '02c-tenant-onboard-step3.png');
    }

    // Step 3: Initialize
    const initBtn = page.locator('button', { hasText: /Initialize|初始化|创建/ });
    if (await initBtn.isVisible()) {
      await initBtn.click();
      await sleep(3000);
      await screenshot(page, '02d-tenant-onboard-done.png');
    }

    // ===================================================================
    // 3. Tenant Admin — Soul Edit
    // ===================================================================
    console.log('\n=== 3. Soul Edit ===');
    await gotoAuth(page, `/autoservice/admin?as=admin&workspace=${WS}`);
    await screenshot(page, '03a-soul-editor-initial.png');

    // Edit soul content (skip if readonly — cap gate protects editing)
    const soulTextarea = page.locator('textarea[name="soul"]');
    if (await soulTextarea.isVisible()) {
      const isReadonly = await soulTextarea.getAttribute('readonly');
      if (isReadonly === null) {
        const currentSoul = await soulTextarea.inputValue();
        const newSoul = currentSoul + '\n\n## 额外说明\n这是通过 E2E 测试添加的内容。';
        await soulTextarea.fill(newSoul);
        await sleep(500);
        await page.locator('button', { hasText: '保存' }).first().click();
        await sleep(1000);
        await screenshot(page, '03b-soul-editor-saved.png');
      } else {
        console.log('  ⚠️ Soul editor is readonly (cap gate), skipping edit');
      }
    }

    // ===================================================================
    // 4. Slots Edit
    // ===================================================================
    console.log('\n=== 4. Slots Edit ===');
    await gotoAuth(page, `/autoservice/admin?as=admin&workspace=${WS}`);
    const slotsTextarea = page.locator('textarea[name="slots"]');
    if (await slotsTextarea.isVisible()) {
      const isReadonly = await slotsTextarea.getAttribute('readonly');
      if (isReadonly === null) {
        const newSlots = 'brand_name: "Cinnox"\nindustry: "通讯"\nservice_hours: "7×24小时"\ntest_key: "E2E测试值"';
        await slotsTextarea.fill(newSlots);
        await sleep(500);
        const saveBtns = page.locator('button', { hasText: '保存' });
        if (await saveBtns.count() >= 2) {
          await saveBtns.nth(1).click();
          await sleep(1000);
        }
        await screenshot(page, '04-slots-editor-saved.png');
      } else {
        console.log('  ⚠️ Slots editor readonly, taking screenshot of current state');
        await screenshot(page, '04-slots-editor-readonly.png');
      }
    }

    // ===================================================================
    // 5. Skills — Create + Edit
    // ===================================================================
    console.log('\n=== 5. Skills ===');
    await gotoAuth(page, `/autoservice/admin?as=admin&workspace=${WS}`);

    // Switch to Skills tab
    const skillsTab = page.locator('button', { hasText: 'Skills' });
    if (await skillsTab.isVisible()) {
      await skillsTab.click();
      await sleep(1000);
    }
    await screenshot(page, '05a-skills-tab.png');

    // Try creating a skill (skip input if not visible/disabled)
    const skillNameInput = page.locator('input[name="name"]');
    const hasSkillInput = await skillNameInput.isVisible().catch(() => false);
    if (hasSkillInput) {
      const skillReadonly = await skillNameInput.getAttribute('readonly');
      if (skillReadonly === null) {
        await skillNameInput.fill('e2e-test-skill');
        await page.locator('button', { hasText: '创建' }).click();
        await sleep(1000);
        await screenshot(page, '05b-skill-created.png');

        // Edit the skill
        const editBtn = page.locator('button', { hasText: '编辑' }).first();
        if (await editBtn.isVisible()) {
          await editBtn.click();
          await sleep(800);
          const skillEditor = page.locator('textarea[name="content"]');
          if (await skillEditor.isVisible()) {
            const contentReadonly = await skillEditor.getAttribute('readonly');
            if (contentReadonly === null) {
              await skillEditor.fill('# E2E Test Skill\n\nThis skill was created during E2E testing.\n\n## 功能\n- 测试 skill 编辑功能\n- 验证保存和删除');
              await page.locator('button', { hasText: '保存' }).last().click();
              await sleep(1000);
            }
          }
          await screenshot(page, '05c-skill-edited.png');
        }
      } else {
        console.log('  ⚠️ Skill input readonly, skipping create');
      }
    }

    // ===================================================================
    // 6. KB — Add Entry
    // ===================================================================
    console.log('\n=== 6. KB Entry ===');
    await gotoAuth(page, `/autoservice/admin?as=admin&workspace=${WS}`);
    const kbTab = page.locator('button', { hasText: 'KB' });
    if (await kbTab.isVisible()) {
      await kbTab.click();
      await sleep(1000);
    }
    await screenshot(page, '06a-kb-tab.png');

    const kbId = page.locator('input[name="id"]');
    const hasKbId = await kbId.isVisible().catch(() => false);
    if (hasKbId) {
      const kbReadonly = await kbId.getAttribute('readonly');
      if (kbReadonly === null) {
        await kbId.fill('e2e-kb-entry');
        const kbTitle = page.locator('input[name="title"]');
        if (await kbTitle.isVisible()) await kbTitle.fill('E2E 测试知识库条目');
        const kbContent = page.locator('textarea[name="content"]');
        if (await kbContent.isVisible()) await kbContent.fill('这是通过 E2E 测试添加的 KB 条目内容。包含测试数据和验证信息。');
        await page.locator('button', { hasText: '添加' }).click();
        await sleep(1500);
        await screenshot(page, '06b-kb-entry-added.png');
      } else {
        console.log('  ⚠️ KB input readonly, taking screenshot of current state');
      }
    }

    // ===================================================================
    // 7. CR Publish
    // ===================================================================
    console.log('\n=== 7. CR Publish ===');
    await gotoAuth(page, `/autoservice/admin?as=admin&workspace=${WS}`);
    const publishTab = page.locator('button', { hasText: '发布' });
    if (await publishTab.isVisible()) {
      await publishTab.click();
      await sleep(1000);
      await screenshot(page, '07a-publish-tab.png');

      const publishBtn = page.locator('button', { hasText: '发布' }).last();
      const isDisabled = await publishBtn.isDisabled().catch(() => true);
      if (!isDisabled) {
        await publishBtn.click();
        await sleep(2000);
        await screenshot(page, '07b-publish-after.png');
      } else {
        console.log('  ⚠️ Publish button disabled, taking current state screenshot');
        await screenshot(page, '07b-publish-disabled.png');
      }
    }

    // ===================================================================
    // 8. Operator Console + CR Dashboard
    // ===================================================================
    console.log('\n=== 8. Operator & CR ===');
    await gotoAuth(page, `/autoservice/operator?as=op`);
    await screenshot(page, '08-operator-console.png');

    await gotoAuth(page, `/admin/autoservice/tenants/${WS}/cr?as=admin&workspace=${ADMIN_WS}`);
    await screenshot(page, '09-cr-dashboard.png');

    // Final: Master Dashboard after operations
    await gotoAuth(page, `/admin/autoservice?as=admin&workspace=${ADMIN_WS}`);
    await screenshot(page, '10-master-dashboard-final.png');

    // Close and save video
    await context.close();
    const files = fs.readdirSync(RECORDING_DIR);
    const videoFile = files.find(f => f.endsWith('.webm'));
    if (videoFile) {
      const oldPath = path.join(RECORDING_DIR, videoFile);
      const newPath = path.join(RECORDING_DIR, `autoservice-full-demo-${Date.now()}.webm`);
      fs.renameSync(oldPath, newPath);
      console.log(`\n[done] Video: ${newPath}`);
    }
    console.log('[done] All E2E operations recorded!\n');

  } catch (error) {
    console.error('[error]', error.message);
    console.error(error.stack);
    process.exit(1);
  } finally {
    if (browser) await browser.close();
    if (server) { server.kill('SIGTERM'); console.log('[server] Stopped'); }
  }
}

main();
