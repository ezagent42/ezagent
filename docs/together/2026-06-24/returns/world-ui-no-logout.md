# Return: F3 — world UI 无登出/切号入口

> **Task:** F3 — `fix/world-ui-no-logout`（world UI 登出/切号入口）
> **Branch:** `fix/world-ui-no-logout`
> **PR:** none（已 push，可开 PR：https://github.com/ezagent42/ezagent/pull/new/fix/world-ui-no-logout）
> **Dev:** @李震宇 (zyli) + Claude（实现/验证）
> **returned_at:** 2026-06-24 17:?? +0800
> **deadline:** —（非 2026-06-24 `plan.md` 计划项；派生自当日 full-flow 验证 return 的 F3 finding）
> **deadline_status:** out_of_scope（同日 follow-up 修复，非原始日计划任务；保留计数为 follow-up，不计入当日计划工作量）

## Scope note

本任务不在 `docs/together/2026-06-24/plan.md`（当日计划 = full-flow 人肉验证 +
rebase-batch 4 PR 验证）。它是验证 return 路由给 world UI 开发者本人的 5 个
finding 之一（F3/F9/F10/F13/F14），同日开始修复。base = 最新 `origin/main`
(`c4bcebe3`)。

## What's done

**F3**：world React SPA（`world.localhost` 操作台）此前无登出/切号入口——`POST /logout`
路由早已存在，但前端从未暴露（只有 LiveView shell 的 avatar 菜单暴露过）。

改动（单文件，纯前端）`apps/ezagent_plugin_world/assets/src/main.tsx`（+86/-1）：

1. world shell header 新增 `AccountMenu`（与 workspace 切换 / 主题 / Command 并列）：
   display-name 按钮 → 下拉，唯一动作 **Sign out**，支持点外部 / Esc 关闭。
2. **Sign out = CSRF 保护的 `POST /logout` controller 表单**——复用 `ide_shell.ex:599`
   已验证可用的写法；token 从 root layout 的 `<meta name="csrf-token">`（root.html.heex
   已有）读取。走 controller 表单而非 `world:dispatch`：清 HTTP session cookie 在请求层、
   不在 LiveView channel。
3. 切号 = logout + re-auth（SPEC v3 §6.4，无 in-place context swap），故 "Sign out"
   同时是切号入口；workspace 切换另有 `/workspaces` 入口。
4. 补 `caller.display_name` 的 TS 类型（WorldLive 早已在 `caller_payload` 传，类型漏声明）
   + lucide `User`/`LogOut` 图标。

Commits:
- `54e097fe feat(world): expose logout / switch-account entry in world UI header (F3)`
- `0ab87eaa fix(world): drive logout POST programmatically so LiveView can't swallow it`（活体验证抓到的 submit 拦截 bug）

## Gate status

| Gate | 结果 |
|---|---|
| `vite build`（项目真正的构建 gate，esbuild 转译 JSX）| ✅ green — 新组件正确打包 |
| `check:mounts`（typed-slot 闸门）| ✅ green — AccountMenu 是 header chrome，非 layout-slot surface，不触发 |
| `lv_parity` | N/A — 不引入新 `world:dispatch` action（logout 是 controller 路由） |
| 裸 `tsc --noEmit` | ⚠️ 预存在失败（tsconfig `moduleResolution` 在 TS6 弃用 + 项目 devDeps 未装 `@types/react`；origin/main 我改之前同样失败）——本项目类型 gate 走 vite/esbuild，非裸 tsc |

## DoD artifact —— ✅ 活体 agent-browser 验证通过（含抓到并修掉一个真 bug）

活体验证手段：把改好的 `main.tsx` **临时**复制进运行中主仓的同一文件，靠 vite HMR 让
:10042 的 server 直接渲染（后端/PG/编译均未动），agent-browser 实测后 `git checkout`
还原主仓（主仓是 docs-only 验证分支，main.tsx == origin/main，还原干净）。

**实测抓到真 bug（build/静态检查发现不了）**：初版点 "Sign out" **毫无反应**——网络里
根本没有 `POST /logout`，session 仍认证。world 是 LiveView 页，其 client JS 截获了
`phx-update="ignore"` React 岛内 form 的原生 submit 事件并吞掉。`form.submit()`（绕过
submit 事件）能正常登出，证明 form/路由/CSRF 都对、只是事件路径被挡。
→ 修复 commit `0ab87eaa`：Sign out 的 onClick `preventDefault()` + 程序化 `formRef.submit()`。

**修复后端到端复测（点真按钮）**：
1. admin 登录 → `/sessions`（world shell，header 出现 `Admin ▾` 账户菜单）
2. 点开菜单 → 显示 `Admin` + `entity://system/user/admin` + 玫红 `Sign out`
3. **点 Sign out → 302 跳 `/login`**
4. 重新请求 `/sessions` → 被 `require_entity` 弹回 `/login`（session 已清）

证据截图：`docs/together/2026-06-24/evidence/f3-world-ui-logout/`
- `01-account-menu-open.png` — header 账户菜单展开
- `02-after-logout-login-page.png` — 点 Sign out 后落在登录页

## Merge request

- 分支 `fix/world-ui-no-logout`（已 push，tracking `origin/fix/world-ui-no-logout`）。
- 无与他人 owned surface 的冲突：唯一改动文件 `main.tsx`，且只在 header 增量插入。
- 顺序无依赖，可独立 merge。
- **merge gate 已满足**：活体端到端登出已验证（见上 DoD），无遗留 gate。

## 同 owner 的其余 finding（尚未动）

F13（anon chat composer）· F9（飞书绑群 UI，半阻塞需 @林懿伦 暴露 action）·
F10（agent 配 key UI，半阻塞需 @黄佳佳 暴露 action）· F14（UI Disable 更新 ETS）。
