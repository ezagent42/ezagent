# World UI IM Refactor Smoke Test Results

Date: 2026-06-30 16:46-17:52 Asia/Taipei

Worktree: `/home/lenovo/workspace/ezagent/.worktrees/world-ui-im-refactor-0630`

Service under test:

- Local Phoenix: `http://world.localhost:10043`
- Local World Vite: `http://world.localhost:5174/src/main.tsx`
- Login: dev admin account

## Findings

1. Opening `http://100.64.0.20:10043/sessions` through the current proxy path returned `HTTP 502`.
   - Root cause: `100.64.0.20` must bypass the local HTTP proxy.
   - Local browser validation should use `world.localhost`, not the tailnet IP.

2. After bypassing the proxy, login initially worked but `/sessions` stayed on the loading spinner.
   - Root cause: the worktree did not have `apps/ezagent_web/assets/node_modules`, so the web shell esbuild watcher could not produce `/assets/js/app.js`.
   - Recovery performed: `npm install` in `apps/ezagent_web/assets`, then `mix esbuild ezagent_web`.

3. Local `world.localhost` verification:
   - Restarted the worktree service with `world_module_url` set to `http://world.localhost:5174/src/main.tsx`.
   - `curl --noproxy '*' http://world.localhost:10043/_health` returned 200.
   - `curl --noproxy '*' http://world.localhost:10043/assets/js/app.js` returned 200.
   - `curl --noproxy '*' http://world.localhost:5174/src/main.tsx` returned 200.
   - Browser login at `http://world.localhost:10043/login` rendered the sessions list.
   - Network requests used `world.localhost:10043` and `world.localhost:5174`; no `100.64.0.20` requests appeared in the browser smoke run.

4. PR #1104 prototype alignment check:
   - The GitHub diff anchor `diff-7029cb074c920e0d7b064c544fc9fc1bcc5c75ba5341927ef7188abbf34f6782` maps to `docs/together/2026-06-30/world-ui-redesign-prototype.html`.
   - The production World shell now exposes `data-world-shell="prototype"`, `data-world-topbar`, and `data-world-primary-nav`.
   - Browser DOM check on `world.localhost` returned nav labels `Chat`, `Agents`, `Manage`.
   - Chat detail DOM check returned `im: true`, `filter: true`, and a chat frame rect of `top: 54`, `height: 666`, `width: 1440`.
   - `agent-browser errors` returned no browser errors after the prototype alignment run.

## Screenshots

- `01-unauth-sessions-entry.png`: proxy path failure, HTTP 502.
- `02-login-noproxy.png`: login page after proxy bypass.
- `03-sessions-after-login.png`: spinner before `/assets/js/app.js` existed.
- `04-login-fixed-assets.png`: login page after asset recovery.
- `05-sessions-list-rendered.png`: sessions list rendered after login.
- `06-session-detail-after-open.png`: selected session detail, IM chat layout.
- `07-workspace-switcher-open.png`: workspace switcher menu.
- `08-admin-menu-open.png`: Admin menu.
- `09-agents-page.png`: Agents page.
- `10-manage-page.png`: Manage / Workspaces page.
- `11-world-localhost-login.png`: login page via `world.localhost`.
- `12-world-localhost-sessions.png`: sessions list via `world.localhost`.
- `13-world-localhost-session-detail.png`: selected session detail via `world.localhost`.
- `14-prototype-topbar-sessions.png`: sessions list after aligning the production shell to PR #1104's topbar prototype.
- `15-prototype-chat-detail.png`: selected session detail after aligning the Chat frame to PR #1104's three-column prototype.
