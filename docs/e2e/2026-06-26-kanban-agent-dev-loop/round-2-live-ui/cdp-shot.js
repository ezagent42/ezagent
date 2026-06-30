// 用 raw CDP 给一个需登录的 URL 截图：注入 _ezagent_web_key cookie → navigate → 截图。
// 用法: COOKIE=... SHOT_URL=... OUT=... node cdp-shot.js
const http = require('http');

const COOKIE = process.env.COOKIE;
const SHOT_URL = process.env.SHOT_URL;
const OUT = process.env.OUT;
const WAIT_MS = parseInt(process.env.WAIT_MS || '4500', 10);

function getJSON(path) {
  return new Promise((res, rej) => {
    http.get({ host: '127.0.0.1', port: 9222, path }, (r) => {
      let d = '';
      r.on('data', (c) => (d += c));
      r.on('end', () => res(JSON.parse(d)));
    }).on('error', rej);
  });
}

async function main() {
  // 找一个 page target
  let targets = await getJSON('/json');
  let page = targets.find((t) => t.type === 'page');
  if (!page) throw new Error('no page target');
  const ws = new WebSocket(page.webSocketDebuggerUrl);
  let id = 0;
  const pending = new Map();
  const send = (method, params = {}) =>
    new Promise((res) => {
      const mid = ++id;
      pending.set(mid, res);
      ws.send(JSON.stringify({ id: mid, method, params }));
    });

  await new Promise((res) => (ws.onopen = res));
  ws.onmessage = (ev) => {
    const m = JSON.parse(ev.data);
    if (m.id && pending.has(m.id)) {
      pending.get(m.id)(m.result);
      pending.delete(m.id);
    }
  };

  await send('Network.enable');
  await send('Page.enable');
  // 注入认证 cookie（world.localhost 域）
  await send('Network.setCookie', {
    name: '_ezagent_web_key',
    value: COOKIE,
    domain: 'world.localhost',
    path: '/',
    httpOnly: true,
  });
  await send('Page.navigate', { url: SHOT_URL });
  await new Promise((r) => setTimeout(r, WAIT_MS)); // 等 SPA 渲染
  const { data } = await send('Page.captureScreenshot', { format: 'png' });
  require('fs').writeFileSync(OUT, Buffer.from(data, 'base64'));
  console.log('SHOT_OK ' + OUT + ' bytes=' + Buffer.from(data, 'base64').length);
  ws.close();
  process.exit(0);
}

main().catch((e) => {
  console.error('SHOT_ERR ' + (e && e.message));
  process.exit(1);
});
