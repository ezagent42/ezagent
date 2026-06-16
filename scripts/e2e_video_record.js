/**
 * AutoService Admin UI E2E Video Recorder
 *
 * Uses Playwright to:
 * 1. Start the Phoenix dev server
 * 2. Log in as admin via DevAutoLogin (?as=admin)
 * 3. Navigate through all admin pages, recording video
 * 4. Save the recording to scripts/e2e_recordings/
 *
 * Usage: node scripts/e2e_video_record.js
 */

const { chromium } = require('playwright');
const { spawn } = require('child_process');
const path = require('path');
const fs = require('fs');

const BASE_URL = 'http://localhost:10042';
const RECORDING_DIR = path.join(__dirname, 'e2e_recordings');
const VIDEO_FILE = path.join(RECORDING_DIR, `autoservice-admin-${Date.now()}.webm`);

// Pages to visit in order
const DEFAULT_WS = 'cinnox';
const ADMIN_WS = 'system';  // admin pages require system workspace

const PAGES = [
  {
    name: '01-master-dashboard',
    path: `/admin/autoservice?as=admin&workspace=${ADMIN_WS}`,
    description: 'Master Admin Dashboard — tenant overview, KPI cards, tenant list'
  },
  {
    name: '02-tenant-onboard',
    path: `/admin/autoservice/tenants/new?as=admin&workspace=${ADMIN_WS}`,
    description: 'Tenant Onboard Wizard — Step 1 of 3'
  },
  {
    name: '03-cr-dashboard',
    path: `/admin/autoservice/tenants/${DEFAULT_WS}/cr?as=admin&workspace=${ADMIN_WS}`,
    description: 'CR Dashboard — active CR status, CR history'
  },
  {
    name: '04-tenant-admin-soul-slots',
    path: `/autoservice/admin?as=admin&workspace=${DEFAULT_WS}`,
    description: 'Tenant Admin — Soul & Slots tab (cap-gated: read-only if no content:write)'
  },
  {
    name: '05-tenant-admin-skills',
    path: `/autoservice/admin?as=admin&workspace=${DEFAULT_WS}`,
    description: 'Tenant Admin — Skills tab'
  },
  {
    name: '06-tenant-admin-kb',
    path: `/autoservice/admin?as=admin&workspace=${DEFAULT_WS}`,
    description: 'Tenant Admin — KB tab'
  },
  {
    name: '07-tenant-admin-fast-agent',
    path: `/autoservice/admin?as=admin&workspace=${DEFAULT_WS}`,
    description: 'Tenant Admin — Fast Agent Prompt tab'
  },
  {
    name: '08-tenant-admin-publish',
    path: `/autoservice/admin?as=admin&workspace=${DEFAULT_WS}`,
    description: 'Tenant Admin — Publish tab (CR + Lint + Preview)'
  },
  {
    name: '09-operator-console',
    path: `/autoservice/operator?as=op`,
    description: 'Operator Console — CS session list'
  }
];

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

  // Wait for server to be ready
  let output = '';
  server.stdout.on('data', (data) => { output += data.toString(); });
  server.stderr.on('data', (data) => { output += data.toString(); });

  // Poll until server returns 200 or 302 (not 503 Service Unavailable)
  for (let i = 0; i < 180; i++) {
    try {
      const resp = await fetch(`${BASE_URL}/login`);
      if (resp.status === 200 || resp.status === 302) {
        console.log(`[server] Phoenix server is ready (HTTP ${resp.status})`);
        await sleep(3000); // extra settle time for LiveView
        return server;
      }
      if (resp.status > 0 && resp.status !== 503) {
        console.log(`[server] Got HTTP ${resp.status}, waiting for 200...`);
      }
    } catch (e) {
      // Server not ready yet
    }
    if (i % 15 === 0 && i > 0) {
      console.log(`[server] Still waiting... (${i}s)`);
    }
    await sleep(1000);
  }
  throw new Error('Server failed to start within 180s');
}

async function recordPage(page, pageInfo) {
  console.log(`[record] ${pageInfo.name}: ${pageInfo.description}`);

  await page.goto(`${BASE_URL}${pageInfo.path}`, {
    waitUntil: 'networkidle',
    timeout: 15000
  });

  // Wait for LiveView to mount
  await page.waitForSelector('[data-phx-main]', { timeout: 10000 }).catch(() => {});
  await sleep(2000);

  // Take a screenshot
  const shotPath = path.join(RECORDING_DIR, `${pageInfo.name}.png`);
  await page.screenshot({ path: shotPath, fullPage: true });
  console.log(`  screenshot: ${shotPath}`);
}

async function main() {
  // Ensure recording directory exists
  if (!fs.existsSync(RECORDING_DIR)) {
    fs.mkdirSync(RECORDING_DIR, { recursive: true });
  }

  let server;
  let browser;

  try {
    // Start server
    server = await startServer();

    // Launch browser with video recording
    browser = await chromium.launch({ headless: true });
    const context = await browser.newContext({
      viewport: { width: 1440, height: 900 },
      recordVideo: { dir: RECORDING_DIR, size: { width: 1440, height: 900 } }
    });

    const page = await context.newPage();

    // Visit each page
    for (const pageInfo of PAGES) {
      await recordPage(page, pageInfo);
    }

    // For TenantAdminLive tabs, use a fresh page view to interact with tabs
    console.log('[record] TenantAdminLive tab interactions...');

    await page.goto(`${BASE_URL}/autoservice/admin?as=admin&workspace=${ADMIN_WS}`, {
      waitUntil: 'networkidle',
      timeout: 15000
    });
    await page.waitForSelector('[data-phx-main]', { timeout: 10000 }).catch(() => {});
    await sleep(2000);

    // Click Skills tab
    const skillsBtn = page.locator('button', { hasText: 'Skills' });
    if (await skillsBtn.isVisible()) {
      await skillsBtn.click();
      await sleep(1000);
      await page.screenshot({ path: path.join(RECORDING_DIR, '05b-skills-tab-clicked.png'), fullPage: true });
      console.log('  Skills tab clicked');
    }

    // Click KB tab
    const kbBtn = page.locator('button', { hasText: 'KB' });
    if (await kbBtn.isVisible()) {
      await kbBtn.click();
      await sleep(1000);
      await page.screenshot({ path: path.join(RECORDING_DIR, '06b-kb-tab-clicked.png'), fullPage: true });
      console.log('  KB tab clicked');
    }

    // Click Fast Agent tab
    const faBtn = page.locator('button', { hasText: 'Fast Agent' });
    if (await faBtn.isVisible()) {
      await faBtn.click();
      await sleep(1000);
      await page.screenshot({ path: path.join(RECORDING_DIR, '07b-fast-agent-tab-clicked.png'), fullPage: true });
      console.log('  Fast Agent tab clicked');
    }

    // Click Publish tab
    const pubBtn = page.locator('button', { hasText: '发布' });
    if (await pubBtn.isVisible()) {
      await pubBtn.click();
      await sleep(1000);
      await page.screenshot({ path: path.join(RECORDING_DIR, '08b-publish-tab-clicked.png'), fullPage: true });
      console.log('  Publish tab clicked');
    }

    // Close to save video
    await context.close();

    // Find the saved video and rename it
    const files = fs.readdirSync(RECORDING_DIR);
    const videoFile = files.find(f => f.endsWith('.webm'));
    if (videoFile) {
      const oldPath = path.join(RECORDING_DIR, videoFile);
      fs.renameSync(oldPath, VIDEO_FILE);
      console.log(`[done] Video saved: ${VIDEO_FILE}`);
    }

    console.log('[done] All pages recorded successfully!');

  } catch (error) {
    console.error('[error]', error.message);
    process.exit(1);
  } finally {
    if (browser) await browser.close();
    if (server) {
      server.kill('SIGTERM');
      console.log('[server] Stopped');
    }
  }
}

main();
