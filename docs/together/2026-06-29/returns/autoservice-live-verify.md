# FP2 AutoService Live Verify — 2026-06-29 (整合报告)

**Owner:** gaga  
**整合自：**  
- `verify/autoservice-live` (gaga 主线, PORT=10044)  
- `worktree-verify+autoservice-live-codex` (独立验证线, PORT=10144)  
**Stack:** local disposable（无 Docker）  
**Seed script:** `scripts/autoservice_tier1_serve_seed.exs`

---

## S1-S4 确定性链：验证结果

| 步骤 | 验证方式 | 结果 |
|---|---|---|
| S1 anon landing | `curl http://localhost:10044/socialware/chat?session_uri=...` → HTTP 200 | ✓ GREEN |
| S1 external landing | `GET /socialware/external?session_uri=...` → HTTP 200 shell | ✓ GREEN |
| S2a 路由规则 | seed 输出：`always(in_session)→AutoService-agent id=2` | ✓ GREEN |
| S3 KB 检索 ZEPHYR-7731 | `mix test apps/ezagent_plugin_kb/test/e2e/autoservice_tier1_seed_test.exs` — 2 tests, 0 failures | ✓ GREEN |
| S3 KB live IEx probe | `Orchestrator.Tools.kb_query/4` → `{:ok, %{chunks: [...]}}` 含 ZEPHYR-7731 | ✓ GREEN |
| S3 message routing | `session.send` 存储 + routed_at 标记 + fan-out invocation granted | ✓ GREEN |
| S4 cc answer-loop | cc-flavor orchestrator 创建失败 | BLOCKED (known gap) |
| arch.scan | `mix ezagent.arch.scan` — 全部 fitness function PASS | ✓ GREEN |
| check_invariants | `mix ezagent.check_invariants` — 8 条硬不变式全绿 | ✓ GREEN |

Seed 输出（节选）：
```
workspace        : workspace://autosvc
kb-agent         : entity://autosvc/agent/kb-tier1  (fact: ZEPHYR-7731)
AutoService agent: entity://autosvc/agent/autoservice  (status: {:blocked, {:autoservice_agent_create_failed, {:role_unsupported_for_flavor, "cc"}}})
session          : session://autosvc/default/tier1
route            : always(in_session)→AutoService-agent  id=2
```

---

## S4 cc answer-loop：BLOCKED — 已知缺口

**错误**：`{:autoservice_agent_create_failed, {:role_unsupported_for_flavor, "cc"}}`  
**根因**：`Workspace.create_agent/3` 对 `cc` flavor 不支持。cc-flavor orchestrator **必须经 `session-create orchestrator-template` 路径物化**，不走 `create_agent`。  
**状态**：seed 代码 best-effort 设计（不 crash），S1/S2a/S3 链已完整 wired，cc 物化是剩余工作项。  
**cc 物化路径**（未验证）：`session-create orchestrator-template` → `SessionManager.load_orchestrator_caps/1` → kb.query cap → MCP bridge 暴露 `kb_query` 工具 → message → cc answer weaving ZEPHYR-7731。

---

## WS Surface（codex 额外覆盖）

| 探针 | 结果 | 说明 |
|---|---|---|
| Chat topic join | ✓ success | snapshot 返回空 |
| Chat `join`/`post`/`history` event | `read_only` | ChatFeedAdapter.participation_profile = :read_only，符合设计 |
| External topic join | ✓ success | snapshot 返回空 |
| External anon `join`/`post` | `not_logged_in` | 设计行为，见 BUG-3 分析 |
| External `history` | 返回空消息列表 | ✓ 正常 |

---

## Bug Triage（4 条，2 条需修复）

### BUG-1 — 缺少 rename migration【MEDIUM — 需修复】

**症状**：`EzagentWeb.Socialware.ExternalFeedSocketTest` 7 tests 报 `ERROR 42P01 undefined_table "socialware_delivery_outbox"`  
**根因**：测试 DB 从旧 SQLite-era 建立，只有 `socialware_customer_outbox`（旧名）。`pg_baseline`（`20260622000000`）创建了 `socialware_delivery_outbox`（新名），但缺少将老 DB 中旧表 rename 的迁移。  
**受影响**：所有在旧 DB 上运行测试的开发者；全新 checkout + `mix ecto.create` 不受影响（pg_baseline 直接建新名）。  
**临时缓解**：`MIX_ENV=test mix ecto.reset`（重建 test DB）→ 验证后 14 tests, 0 failures。  
**正确修复**：
```elixir
# priv/repo_pg/migrations/YYYYMMDD_rename_customer_outbox_to_delivery_outbox.exs
execute "ALTER TABLE socialware_customer_outbox RENAME TO socialware_delivery_outbox;"
```

---

### BUG-2 — Chat/External 页面 "Unsupported node: container"【MEDIUM — 需修复】

**症状**：`/socialware/chat` 和 `/socialware/external` 页面在空状态下渲染 "Unsupported node: container"（codex 截图确认：chat 页面报错可见）。  
**根因（git 溯源）**：  
- `viewer_app.js:760`：`emptyPage()` 返回 `{type: "container", props: {layout: "stack"}, children: []}`  
- `viewer_app.js:4`：`import {JsonRenderPage} from "./catalog_jsonrender.mjs"` — 使用 shadcn 渲染器  
- `catalog_jsonrender.mjs` 使用 `@json-render/shadcn`（Vercel 官方 React 19 组件库），对未知节点类型返回 `Unknown` fallback → "Unsupported node: container"  
- `catalog_jsonrender.mjs` **不包含** `container` 类型（它在 `catalog.mjs` 的 `CATALOG_TYPES` 里，供旧 `catalog_render.mjs` 使用）

**Regression 时间线**：  
- PR #1037（`c7f086d6`）：`customer_app.js` → `viewer_app.js`，同时引入 `catalog_jsonrender.mjs`，此时 `emptyPage()` 中 `container` 类型与新渲染器不兼容  
- PR #1069（`e825e032`）：修改了 `viewer_app.js` 但未修复此 mismatch  

**影响范围**：两个 controller 都加载 `viewer_app.js`：  
- `chat_feed_controller.ex:140`  
- `external_feed_controller.ex:166`  

**修复方向**：将 `emptyPage()` 中的 `{type: "container", ...}` 替换为 `catalog_jsonrender.mjs` 支持的等效空页面节点类型（如 `Stack`），或在 `catalog_jsonrender.mjs` 中为 `container` 注册 passthrough。

---

### BUG-3 — Anonymous external WS join/post 返回 `not_logged_in`【BY DESIGN — 非 bug】

**症状**：匿名用户对 external feed WS channel 发送 `join`/`post` 事件 → `not_logged_in`  
**溯源**：  
- `session_feed_channel.ex:312-314`：`signed_in_principal/1` 对 anon URI（`AnonUser.anon_uri?/1`）显式返回 `nil`  
- `handle_participatory_join/3`（L197-227）：要求 `signed_in_principal` 非 nil → anon 走 `not_logged_in` 分支  
- PR #1047（`d730b989`，"unify socialware feed adapters"）明确引入此模式  
**设计意图**：匿名用户通过 HTTP snapshot（`ExternalFeedController` / `AnonIngress`）查看外部 feed；WS channel 参与（posting）要求真实登录身份。WS topic join 本身成功，是 `join` 事件（参与申请）需要登录。  
**结论**：非 regression，不需修复。

---

### BUG-4 — Vite dev watcher pnpm shim 问题【DEV ONLY — 环境问题】

**症状**：Phoenix dev watcher 启动后反复报 `SyntaxError: missing ) after argument list`（node 尝试 parse shell shim）  
**根因**：Phoenix watcher 调用 `node node_modules/.bin/vite`，pnpm 的 `.bin/vite` 是 shell shim，Node 解析失败。静态资产已通过 `mix assets.build` 预构建，不影响 HTTP/WS 验证。  
**影响**：仅影响 dev watcher live reload，不影响 live 验证和测试。  
**结论**：开发环境问题，不影响 CI/prod。

---

## Pending

- [ ] **#110 live 三环境验证**：待 Allen promotion（nightly→beta→stable），promotion 完成后跑验证截图
- [ ] **S4 cc answer-loop**：cc-flavor orchestrator 物化（session-create orchestrator-template 路径）

---

## 已完成清单

- [x] fresh disposable 栈搭建 × 2（两条独立验证线）
- [x] `mix ezagent.bootstrap` + admin 密码设置（自生成，未问 Allen）
- [x] in-node seed 跑通（两线一致）
- [x] S1/S2a/S3 live 绿（HTTP 200 + routing id=2 + 2 E2E tests pass）
- [x] S3 KB live IEx probe 绿（ZEPHYR-7731 chunks 返回）
- [x] S3 message/routing DB evidence 验证（routed_at + invocation granted）
- [x] WS surface 探针（chat read_only / external anon not_logged_in 行为确认）
- [x] S4 cc answer-loop 状态文档化（BLOCKED, known gap）
- [x] arch.scan all PASS
- [x] check_invariants all green
- [x] BUG-1 根因确认 + 临时缓解验证（ecto.reset → 14 tests, 0 failures）
- [x] BUG-2 根因确认（git 溯源 #1037 regression，viewer_app.js emptyPage 与 catalog_jsonrender.mjs 不兼容）
- [x] BUG-3 git 溯源（#1047 by design，非 regression）
- [x] BUG-4 记录（dev env only）
- [ ] #110 三环境验证（待 Allen promotion）
