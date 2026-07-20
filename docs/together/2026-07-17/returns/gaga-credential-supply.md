# Return: 任务 B —— cc 凭证供给面

> **returned_at:** 2026-07-17 23:20 (+0800) · **deadline:** handoff 未设 · **deadline_status:** on_time
> **From:** gaga · **To:** jjkysy (lead) · **Handoff:** `docs/together/2026-07-16/handoffs/gaga-agent-runtime.md` §4
> **Branch:** `feat/cc-credential-supply`（off main @ d533a5d73）· PR 见下

## DoD 逐行对账

| Handoff DoD | 状态 | 证据 |
|---|---|---|
| e2e：无凭证建会话（角色 skip 且 reason 结构化可查）→ 配凭证 → 触发补物化 → assistant 进成员表、skip 行清掉（可先以数据断言验收） | ✅（handoff 明示的数据断言口径） | `socialware_credential_rematerialize_test.exs`：skip（durable 行）→ workspace-shared 源就位 → `install_session_socialware` 重跑 → 角色进成员表 + `unfilled_agent_role_slots == []` |
| 补物化幂等测试（重复触发不重复建员） | ✅ | 同文件④：重跑后成员 URI 不变；"already joined is skipped" |
| skip telemetry 断言 | ✅ | `socialware_credential_skip_telemetry_test.exs`：`[:ezagent, :socialware, :definition_agents, :skipped]` 携带 role_name + RAW reason |
| gates 全绿 | ✅* | invariants/lifecycle/arch/doc ✓；uri_query 仅剩 main 已知基线（skill_reconcile.ex:142）；两 app 套件 405/1（失败=skill_distribution 本地 seed 基线，同 #1445/#1452 记录） |
| CI 绿 on PR head + rebase main | ⏳ | 已 push，等 CI |

## 关键勘察结论（比 handoff 预估的活少——机制 jjkysy 判断精确："机制对的，缺两头"，两头里还有一头也在）

1. **供给入口①的生产写入器已存在**：`Ezagent.ActionSet.WorkspaceSharedCredentialSource`
   （cap-checked，挂 Workspace Kind，CLI 树自动派生）+ `mix ezagent.credential.adopt`
   （user-default 车道）。本任务补的是**验证 + 双语 guide**（`docs/guide/credential-supply.md`）。
2. **补物化②的管道已存在**：`install_session_socialware/2` 本身幂等且结尾
   `record_unfilled_role_slots(summary.skipped)` 全量重写 skip 行（成功即清）。
   缺的只是 operator 触发面 → 新增 `mix ezagent.session.reinstall_socialware`。
3. **可观测③**：telemetry 已有；真缺口是 reason 三分类——新增
   `:missing_provider_credential`（env-backed provider key 缺失，修法=deploy env，
   区别于 `:missing_credentials` 的"认养凭证源"车道）。additive，world UI 对未知
   tag 有兜底渲染（Conversation.tsx:1253），zyli 侧零改动。

## 与 #1449 的串行约束遵守

`credential_precondition.ex` **零改动**（PR-4 owns the seam）；reason 细化落在
session_creator 的 `reason_tag`（additive 子句），`{:credential_unavailable, flavor}`
正是 PR-4 fail-closed skip 会走的形状——PR-4 落地后 provider-profile 缺 key 自动
归入 `:missing_provider_credential`，无需再动。

## codex #3/#4（用户点名保留的设计输入）——记 follow-up，不在本 PR

- **#3 CLI token 生命周期**：每次参数构造重铸、`expires_at: nil`、终止不撤销
  （PTY spawn_plan.ex:323 与 headless 同病）。修法（label 轮换 + row id 持有 + 终止
  撤销）应两 flavor 一起做——凭证域 follow-up。
- **#4 token 暴露面**：两层 env → 全部工具子进程可读。方向：窄接口凭证代理/
  CLI wrapper；与本任务的"凭证供给面"同域但另一刀口。

## 红线遵守

- 凭证不落 recipe/manifest（只写 UserDefaultSource/WorkspaceSharedSource 表）✓
- host login 不流向 co-tenant（信任 CredentialPrecondition 既有链，未动）✓
- 补物化走既有 install 管道（materialize_definition_agents 门面），不手搓 spawn+join ✓
- 无自动重试环——reinstall 是显式 operator 动作 ✓
- kanban plugin / BoardProvision / world 前端零改动 ✓
