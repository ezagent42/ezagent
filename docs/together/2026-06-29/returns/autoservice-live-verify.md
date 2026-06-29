# FP2 AutoService Live Verify — 2026-06-29

**Owner:** gaga  
**Branch:** verify/autoservice-live  
**Stack:** local disposable (POSTGRES_DB=ezagent_autosvc_disp, EZAGENT_HOME=/tmp/ezagent_autosvc_e2e, PORT=10044)  
**Seed script:** `scripts/autoservice_tier1_serve_seed.exs` (in-node, iex --dot-iex)

---

## 验证结果：S1-S3 确定性链 LIVE GREEN ✓

| 步骤 | 验证方式 | 结果 |
|---|---|---|
| S1 anon landing | `curl http://localhost:10044/socialware/chat?session_uri=session%3A%2F%2Fautosvc%2Fdefault%2Ftier1` | **HTTP 200** ✓ |
| S2a 路由规则 | seed 输出：`always(in_session)→AutoService-agent id=2` | 已创建 ✓ |
| S3 KB 检索 ZEPHYR-7731 | `mix test apps/ezagent_plugin_kb/test/e2e/autoservice_tier1_seed_test.exs` | **2 tests, 0 failures** ✓ |
| arch.scan | `mix ezagent.arch.scan` — 全部 fitness function PASS | ✓ |
| check_invariants | `mix ezagent.check_invariants` — 8 条硬不变式全绿 | ✓ |

Seed 输出（节选）：
```
workspace        : workspace://autosvc
kb-agent         : entity://autosvc/agent/kb-tier1  (fact: ZEPHYR-7731)
AutoService agent: entity://autosvc/agent/autoservice  (status: {:blocked, {:autoservice_agent_create_failed, {:role_unsupported_for_flavor, "cc"}}})
session          : session://autosvc/default/tier1
route            : always(in_session)→AutoService-agent  id=2
```

---

## cc answer-loop 状态报告（S4）：BLOCKED — 已知缺口

**错误**：`{:autoservice_agent_create_failed, {:role_unsupported_for_flavor, "cc"}}`

**根因**：`Workspace.create_agent/3` 对 `cc` flavor 不支持。cc-flavor orchestrator **必须经 `session-create orchestrator-template` 路径物化**，不走 `create_agent`。

**状态**：`autoservice_agent_status: {:blocked, reason}` — seed 代码设计如此（best-effort），S1/S2a/S3 链已完整 wired，cc 物化是剩余工作项。

**cc 物化路径**（未验证，是 S4 的工作）：
1. 通过 session-create 时传入 orchestrator-template
2. `SessionManager.load_orchestrator_caps/1` 加载 kb.query cap
3. orchestrator 通过 MCP bridge 暴露 `kb_query` 工具
4. 发 message → cc answer weaving ZEPHYR-7731

---

## Bug Triage

### BUG-1 — 缺少 rename migration（MEDIUM）

**症状**：`EzagentWeb.Socialware.ExternalFeedSocketTest` 7 tests 全报 `ERROR 42P01 undefined_table "socialware_delivery_outbox"`

**根因**：测试 DB（`ezagent_pg_compat_test`）从旧 SQLite-era 迁移建立，只有 `socialware_customer_outbox`（老名）。pg_baseline（`20260622000000`）创建了 `socialware_delivery_outbox`（新名），但 **缺少把老 DB 里 `socialware_customer_outbox` rename 的迁移**。

**受影响**：所有在旧 DB 上运行测试的开发者；新 checkout + `mix ecto.create` 不受影响（pg_baseline 直接建新名）。

**临时缓解**：`MIX_ENV=test mix ecto.reset`（重建 test DB，验证：reset 后 14 tests, 0 failures）

**正确修复**：新增迁移：
```elixir
# priv/repo_pg/migrations/YYYYMMDD_rename_customer_outbox_to_delivery_outbox.exs
alter table(:socialware_customer_outbox), do: rename_to(:socialware_delivery_outbox)
# 或者: execute "ALTER TABLE socialware_customer_outbox RENAME TO socialware_delivery_outbox;"
```

**优先级**：MEDIUM（阻塞持续 CI 绿，但不影响 live 运行）

---

## #110 live 三环境验证

**状态**：待 Allen promotion（nightly→beta→stable）。Allen promotion 完成后跑验证截图。

---

## 已完成清单

- [x] fresh disposable 栈搭建（POSTGRES_DB=ezagent_autosvc_disp, EZAGENT_HOME=/tmp/ezagent_autosvc_e2e）
- [x] `mix ezagent.bootstrap` + admin 密码设置（自生成，未问 Allen）
- [x] in-node seed 跑通
- [x] S1/S2a/S3 live 绿（HTTP 200 + routing id=2 + 2 E2E tests pass）
- [x] S4 cc answer-loop 状态文档化（BLOCKED, known gap）
- [x] arch.scan all PASS
- [x] check_invariants all green
- [x] Bug triage: BUG-1（rename migration 缺失）根因确认 + 临时缓解验证
- [ ] #110 三环境验证（待 Allen promotion）
