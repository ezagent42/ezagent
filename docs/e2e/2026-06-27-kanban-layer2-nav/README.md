# Layer-2 模块化UI e2e — 左栏一级「看板」入口（声明式 nav_surfaces）

**DoD 达成**：`01-看板-toplevel-nav.png` 真浏览器截图 —— 左栏底部「看板」一级 nav 入口,与 Overview/Sessions/Identities/Admin/Workspaces/Plugins/Profile **并列**(顶层建筑,peer 不是埋在 Plugins 下)。同图可见 GitHub 卡片「GitHub 通用网关（经 gh CLI）」(Phase 2)。

**机制证明(声明式、模块化)**:
- 后端: 服务端 HTML `data-plugin-nav="[{"label":"看板","path":"/plugins/kanban"}]"` —— `Ezagent.Plugin.nav_surfaces/0` 经 `PluginRegistry.list_all` 遍历装了的插件算出、序列化喂前端。**没装 kanban 插件就没这条**(`list_all` 不含 → 无入口)。
- 前端: `main.tsx` WorldApp 合并静态 NAV_ITEMS + 插件声明 nav(React 19,按 path 去重)。
- **复用** kanban 已有 `/plugins/kanban` route/slot/renderer(三层正确,UI 住 world,P13)。

**分级**: **E2E-PASS** —— 真浏览器、真认证(admin)、真渲染(built bundle 同源)、真出现「看板」一级入口。

**dev-env 备注**: 截图用 built bundle(`WORLD_MODULE_URL=/assets/world/main.js`)绕开 Phoenix Vite-watcher 的孤儿占端口崩溃(`:watcher_command_error`,dev.exs 已知问题)+ 跨主机(world.localhost vs localhost:5174)模块 fetch 限制。**与 Layer-2 代码无关**(console 零 JS 运行时错)。
