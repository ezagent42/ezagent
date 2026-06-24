# Handoff: ezagent 官网 — for @张宁

> **Date:** 2026-06-24 · **From:** lead (@林懿伦) · **To:** @张宁 (zhaomato)
> **Tracking:** goal ② — "建官网" · **Base:** `origin/main` @ `78d70e21`
> **Status:** confirmed — 你**先起草**内容/栏目/托管/路由，发群里，**全员一起排版**

## 0. Mission
建 ezagent 官网，复用 hello 已在用的**真** `@json-render` 渲染底座（不另起一套技术栈）。流程是你主导：**你先草一版**内容、栏目、托管方式、公开路由，**发到群里**；然后**团队一起帮你排版**（layout）。你刚接手，先把范围草出来，团队再合力把首屏做出来。

## 1. Task
1. **起草 → 发群**：内容（官网讲什么）、栏目划分（sections）、托管方式、公开路由。先发群、不闷头写。
2. **复用 hello 的 `@json-render` 底座**：照搬 hello 已验证的用法（见 §3），用 JSON 描述页面、catalog 注册组件、registry 渲染。
3. **全员排版**：栏目布局由群里一起定，你落地。

## 2. Branch
`feat/official-site`

## 3. Architecture primer —— 复用 hello 的真 `@json-render`（已核对代码）
hello 插件的前端资产就是参考样板（**只读参考，不要改 hello 的文件**）：
- `apps/ezagent_plugin_hello/assets/package.json` —— 依赖即底座：`@json-render/core` `0.19.0` + `@json-render/react` `0.19.0` + `react` `^19.2.3` + `react-dom`，`@vitejs/plugin-react`，vite 构建。
- `apps/ezagent_plugin_hello/assets/src/catalog.ts` —— 组件目录（哪些组件可被 JSON 引用）。
- `apps/ezagent_plugin_hello/assets/src/registry.tsx` —— 组件注册 / 渲染装配。
- `apps/ezagent_plugin_hello/assets/src/main.tsx` + `assets/js/hello_renderer.js` + `vite.config.ts` —— 入口 + 构建配置样板。
官网照这个 shape 新建**自己的** assets 区，用同样的 `@json-render/core`+`react` 0.19.0、同样的 catalog/registry 模式 —— 把它当模板抄，不改 hello。

## 4. Owned surfaces（你新建，不动别人的）
- **新建官网的 assets / 站点区**（沿用 hello 的 `@json-render` 模式，独立目录）。
- 官网的 JSON 页面描述、自己的 catalog/registry、公开路由配置。
- **明确不动** `apps/ezagent_plugin_hello/assets`（那是 hello owner 的 surface，你只读它当样板）。

## 5. Required reading（动手前）
1. `apps/ezagent_plugin_hello/assets`（整目录 —— `@json-render` 的真实用法：package.json 依赖、catalog.ts、registry.tsx、main.tsx）。
2. #65（CF Workers 部署）—— 托管/部署候选方案。
3. `docs/guide/world-coordination.md` —— **若官网触及 `world`**（公开路由/渲染落在 world 内时必读 + 在其 in-flight registry 加一行）。
4. `dev-together` skill —— 流程 + DoD 标准。

## 6. Definition of Done（可演示 artifact）
- [ ] **官网首屏可访问**：你的 tailnet 地址**发到群里**，团队能打开看到首屏（agent-browser 截图作证据，落 `docs/together/2026-06-24/evidence/`）。
- [ ] 栏目（sections）按群里排版定稿落地。
- [ ] 复用的是 hello 的 `@json-render` 底座（catalog/registry 模式，非另起技术栈）。
- [ ] 涉及代码的部分门禁绿：format、test、（若触 world）arch.scan/check_invariants。

## 7. Discuss-first vs Deferred
**Discuss-first（早会 / 群里先定）：** **官网范围** —— 内容、栏目、托管（是否用 #65 的 CF Workers）、公开路由。你刚接，先把草案发群、团队对齐范围才好起步；排版由全员一起定。
**Deferred（已标）：** CF Workers 正式部署（#65）可在首屏 tailnet 可见之后再做 —— 先 tailnet 起来，托管落地为后续。
**Never deferred here：** 复用 hello 底座这一技术选型（不另起栈）、首屏 tailnet 可见这一 DoD。

## 8. Conflict-avoidance
官网是**新建**站点区，沿用 hello 的 `@json-render` 模式但**独立于** `apps/ezagent_plugin_hello/assets`（只读参考，不改 hello）。若公开路由落在 `world` 内，按 world-coordination.md 在 in-flight registry 登记，避免与 #84/#905 的 world 改动撞车。

## 9. Merge model
PR 合入 `feat/official-site`（绝不直接进 `main`）；保持 rebase 在 `main` 上；首屏 DoD 满足后由 lead（@林懿伦）合 `main`。

## 讨论项（早会 standup — 谁需要在场）
- **官网范围 + 排版。** 参与：**@张宁 起草 → 全员排版** —— @张宁 先草内容/栏目/托管/路由发群，团队（全员）一起帮排版定布局。范围拍板后你落地首屏。
