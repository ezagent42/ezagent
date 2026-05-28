# 场景 29：Admin LV smoke — registry / snapshots / templates / routing / cmdK

**类别**：17 — Admin LV 页面
**状态**：⚠️ implemented-with-gaps
**最近验证**：2026-05-26（per-LV 手动 smoke；`/admin/agents` 404 仍 open）

## 前置条件

- Phx 跑在 `http://100.64.0.27:10042`
- Admin 已登录
- 填充的 workspace（场景 09、14、22 都跑过）

## 角色

- **调用方**：admin
- **目标**：每个 `/admin/*` LV 页面

## 步骤

### 逐 LV 走查

1. `/admin` — 根：workspace 下拉、chat、派发输入。✅
2. `/admin/users` — 列表、mint token、set 密码。✅（按 todo HIGH-4 存在 LV 旁路 gap）
3. `/admin/users/<u>/caps` — 列表、grant、revoke（按 todo 存在 action 选择器 gap）。✅
4. `/admin/workspaces` — 列表。点进一个。✅
5. `/admin/workspaces/<ws>` — 详情：成员、session、模板、routing。✅
6. `/admin/workspaces/<ws>/routing` — per-WS routing 规则 CRUD。✅
7. `/admin/sessions/<s>` — chat + 名册 + 派发。✅
8. `/admin/sessions/<s>/routing` — per-session routing 规则（PR #418 fix）。✅
9. `/admin/sessions/<s>/external-mirror` — 绑定（场景 12）。✅
10. `/admin/agents/<a>/terminal` — live PTY 镜像。✅
11. `/admin/agents/<a>/api-keys` — per-agent api-key（PR #389）。✅
12. `/admin/templates` — 列表 + 创建。✅
13. `/admin/routing` — 全局规则（PR #120 系统默认可见 + 仅 admin 可禁用）。✅
14. `/admin/registry` — live KindRegistry 快照。✅
15. `/admin/snapshots` — kind_snapshots 浏览 + dump + clear。✅
16. `/admin/events` — ❌ 不存在（场景 28）。
17. `/admin/agents`（顶层 agent 列表）— ❌ 今天返回 404（gap）。

### cmdK 搜索

18. 按 `Cmd+K`（或 `Ctrl+K`）；cmdK 面板打开。
19. 输部分 URI：`echo_1`。验证匹配 agent 出现。
20. 输 action 动词：`chat send`。验证它建议对上下文目标的 `chat.send`。
21. 按 SPEC `2026-05-22-v1-uri-pickers-and-cmdk.md`，面板应覆盖 session、entity、action、route。

### Per-Kind admin 自动派生

22. 从 `/admin/registry` 点进 Kind 行。
23. 验证从 `@interface` 编译期生成的自动派生 admin 表单渲染 + 派发正确。

## 预期结果

- **所有** LV 页面在合理大小 DB（<10k 行 / 表）内 1 秒 mount。
- cmdK 键盘驱动 + 响应（无整页重渲染）。
- Workspace 下拉一致过滤所有 per-WS 页面。
- `/admin/agents` 404 是诚实 gap（无 broken-not-404 谜团）。

## 失败模式

- 部署后过期 LV socket：强制重连；assigns 重 mount。
- 并发 admin session：写时乐观并发；PR #422 破坏 + 修复。
- LV action 中切换 workspace：assigns 失效；LV 可能 flash 重定向。

## 交叉引用

- 相关 PR：
  - PR #401 — fix(ui)：icon SVG path-join bug
  - PR #418 — session routing 导航
  - PR #422 — chore(test)：修 umbrella-wide baseline（含 UI 修复）
  - PR #434 — cap-based workspace 可见性（下拉变更）
  - PR #455+ — 待办：`/admin/events` LV
- 相关 SPEC：
  - `docs/superpowers/specs/2026-05-22-v1-uri-pickers-and-cmdk.md`
  - `docs/superpowers/specs/2026-05-20-phase-8b-session-lv-redesign.zh_cn.md`
- 测试：
  - `apps/ezagent_plugin_liveview/test/integration/plugin_contract_test.exs`
- 证据：
  - `docs/notes/phase-9-demo-2026-05-21.md` — LV 截图
- Open bug / gap：
  - `/admin/agents` 404 — 顶层 agent 列表从未发布；admin 用 cmdK 或 per-session 名册替代。
  - `/admin/events` 未发布；场景 28 追踪审计 LV gap。

## 备注

- 按 `feedback_open_terminal_first_when_debugging`，`/admin/agents/<a>/terminal` 是规范的首要调试停靠点。
- 自动派生的 admin 表单（`form_fields/0`）是 plugin 隔离的测试：插件作者**无需**写任何 LV 代码即可获得可用的 admin UI。
- cmdK + URI picker（SPEC `v1-uri-pickers-and-cmdk`）是 `feedback_converge_to_uri_list` 的用户面表现 — 每个输入面最终喂同一 `[URI.t()]` shape。
