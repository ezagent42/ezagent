# Round 2 — 真 world UI 渲染（sanctioned 路径：浏览器）

## 核心证据：`01-board-9stage-chain.png`

admin 登录 world UI 后打开 `/plugins/kanban/<board agent URI>`，**看板完整渲染**：

- 标题 **看板 · board-mgr-7810**（kanban-manager agent 的板）
- **导图列表**：board-mgr-7810 / worker-feat-7810 / board-mgr-12930 …（**list-by-role RF-7** 列出所有 kanban-manager agent 板）
- **画布**：9 阶段接力链（positioning→…→pr）连成流程图
- **本图配置**：GitHub 仓库 `jjkysy/test-ezagent`（set_board_config 写的）+ Miro 板名
- **节点属性**：「定位:习惯养成产品」· unassigned · 定位棒 · **「⚠ gate 未过：这一棒还没挂交付物」**（CI gate 徽章实时显示）
- 右上 **Miro / PR** 出站按钮

→ 证明 kanban-as-role 经真 UI 端到端可用（不只是 dispatch 层）。

## 复现步骤

```bash
# 1. PG + server（vite 避开端口冲突用 5174）
docker compose -f docker-compose.pg.yml up -d
PORT=10042 WORLD_VITE_PORT=5174 mix phx.server   # 见 start-server.sh

# 2. 登录拿 cookie（字段是 email/password，不是 secret）
curl -c cookies.txt http://world.localhost:10042/login        # 取 _csrf_token
curl -b cookies.txt -c cookies.txt -X POST .../login \
  --data-urlencode _csrf_token=... --data-urlencode email=admin@ezagent.chat --data-urlencode password=worlddev

# 3. headless chrome + CDP 注入 cookie 截图
google-chrome --headless=new --remote-debugging-port=9222 --no-sandbox about:blank &
COOKIE=<_ezagent_web_key 值> \
SHOT_URL="http://world.localhost:10042/plugins/kanban/<url-encoded board uri>" \
OUT=board.png node cdp-shot.js
```

## ⚠ 前端 build 坑（这次卡了很久，记下省后人时间）

`/plugins/kanban/...` 页只出 spinner = SPA 的 JS 没服务。根因是**前端没 build**，三处都要：
1. **vite 端口冲突**：别的 worktree 残留 vite 占 :5173 → 本 server vite 起不来。换 `WORLD_VITE_PORT=5174` 或杀孤儿端口。
2. **world island bundle**：`cd apps/ezagent_plugin_world/assets && npm install && npm run build`（出 `ezagent_web/priv/static/assets/world/main.js`）。
3. **主 app.js**（404 的就是它）：`cd apps/ezagent_web/assets && npm install`（缺 `@json-render/react` 等），再 `mix esbuild ezagent_web` + `mix tailwind ezagent_web`（出 `priv/static/assets/js/app.js`）。

三步齐了 app.js 返 200、SPA 才渲染（截图从 7.9KB spinner → 99KB 真内容）。
`cdp-diag.js` 可抓 console 报错定位（就是它抓到 app.js 404 + MIME 错）。
