# 任务 B：cc 凭证供给面 —— 实施计划

> **Handoff:** `docs/together/2026-07-16/handoffs/gaga-agent-runtime.md` §4（jjkysy → gaga）
> **Branch:** `feat/cc-credential-supply`（off origin/main @ d533a5d73）
> **设计输入保留:** codex review PR #1452 #3/#4（token 生命周期/暴露面——见 return open decisions）
> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans；同时 load ezagent-developer + elixir-phoenix-helper。

## 0. 勘察结论

### 已有基础（不重造）

| 模块 | 状态 | 本任务动作 |
|---|---|---|
| `CredentialPrecondition.check_source/3` | 已有，三源链（自有→workspace-shared→NONE→skip），skip 理由粗（`:no_credential_source`） | PR-3：加 `:environment_credential_status` 类别，**provider-aware**（留 `opts \\ []`对口 #1449 PR-4 `opts[:backend_profile]`） |
| `UserDefaultSource` | schema + changeset + `set_via_dispatch/3`（经 CapBAC chokepoint）+ `resolve/3` | ✅ 不动 |
| `WorkspaceSharedSource` | schema + changeset + `resolve/2` + `get/2` | ✅ 不动 |
| `WorkspaceSharedCredentialSource`（Behavior） | `set_shared_source/2` 已实现（`workspace_shared_credential_source.ex:89`——Changeset→Repo.insert/update） | PR-1：暴露此 action 到 CLI/operator dispatch（动作名 `configure_shared_credential`） |
| `mix ezagent.credential.adopt` | 已实现：operator 把已有 agent 的凭证注册为 user 默认源（`UserDefaultSource.set_via_dispatch/3`） | ✅ 不动（v1 operator 路已有） |
| `DefinitionAgents.materialize_definition_agents/4` | 已有幂等语义："already joined is skipped"（session_creator.ex:168） | PR-2：加 `rematerialize_role_slots/3`——对 `unfilled_agent_role_slots` 里的 role 重跑同一管道，返回新创建的 agent URI 列表 + 清 skip 行 |
| `unfilled_agent_role_slots/1` | 读取 session working_copy 上的 skip 行（session_creator.ex:226） | PR-3：补 `clear_unfilled_slot/3`（单 role 清除后的 working_copy 写回） |
| `record_unfilled_role_slots/2` | 已写入 structured reason（`:missing_credentials | :unavailable`） | PR-3：加 telemetry + 细分 `:no_credential_source` vs `:credential_unavailable` |

### 红线验证

- [x] 凭证不落 recipe/manifest（handoff §6）——供给侧只写 `UserDefaultSource`/`WorkspaceSharedSource` 表，不改 manifest
- [x] host login 不流向 co-tenant——信任 `CredentialPrecondition` moduledoc 现有判定链
- [x] 补物化走 `Domain.Agent` 门面——`rematerialize_role_slots` 内部调 `materialize_definition_agents`，不手搓 spawn+join
- [x] 不把 skip 重试做成无限重试假强保证——补物化是**显式触发**（operator 配凭证后手动/自动化调用），不是自动轮询
- [x] 不动 kanban plugin / BoardProvision / 前端（jjkysy 在飞）——本任务只修 credential layer

## 1. 切片（PR 结构，TDD，全部进 feat/cc-credential-supply）

### PR-1 — 凭证供给入口（**勘察后缩水：生产写入器已存在，验证 + 文档**）

勘察实锤：`Ezagent.ActionSet.WorkspaceSharedCredentialSource`（identity 域）已是
cap-checked 生产写入器（`set_workspace_shared_credential_source`，validate 存在/
同 workspace/同 flavor → upsert），注册在 `Ezagent.Entity.Workspace` Kind
（application.ex:478）→ CLI 树自动派生。`UserDefaultCredentialSource` 同理挂 User
Kind；`mix ezagent.credential.adopt` operator task 已有。

- [ ] 验证 `mix ezagent workspace set_workspace_shared_credential_source` 端到端可用
      （admin token → dispatch → 行落表 → `CredentialPrecondition` 三源链能解析到）
- [ ] `docs/guide/credential-supply.md`（+ `.zh_cn.md`）：operator 供给凭证的两条正路
      （user-default via adopt / workspace-shared via workspace action）+ 配好后如何触发
      补物化（PR-2 的 CLI）
- [ ] 若 CLI 端到端有断点（比如 workspace Kind 未 spawn、cap 缺省），修断点本身（不绕过）

### PR-2 — 补物化路（**勘察后收窄：管道已存在且自带清行，缺 sanctioned 触发面**）

勘察实锤：`SessionCreator.install_session_socialware/2` → `SessionInstaller.install/4`
就是幂等重装管道——working_copy 读全部 role slots → `materialize_definition_agents`
（already-joined skip）→ 结尾 `record_unfilled_role_slots(summary.skipped)` **全量覆盖**
skip 行（成功后自动清空）。skip telemetry 也已有（definition_agents.ex:197
`[:ezagent, :session, :socialware_install(?), :skipped]`）。jjkysy 的"机制对的，缺两头"
判断精确。

- [ ] 新 mix task `ezagent.session.reinstall_socialware <session-uri>`：
  - resolve workspace（`Capability.workspace_of`）+ owner（`Session.owner/1`）
  - 调 `install_session_socialware(session_uri, {workspace, owner})`（owner 作 actor →
    composition 授权检查以 owner 身份过——补物化语义=代 owner 重装）
  - 打印 summary（satisfied / skipped+reason），exit 非零 if error
- [ ] 集成测试（复用 #1326 链 C 的 `cc_config_home_credentials_test.exs` setup 基座）：
  - 无凭证 install → assistant skip、`unfilled_agent_role_slots` 有行
  - 配 workspace-shared source → 重跑 install → assistant 进成员表 + skip 行清空
  - 再跑一次 → 幂等（不重复建员，already-joined skip）
  - 凭证仍缺的 role → skip 行保留

### PR-3 — skip 可观测 + telemetry + provider-aware reason 细化
- [ ] `CredentialPrecondition.check_source/3` 加 `opts \\ []`（不改变 3-arity 签名，向后兼容）
  - 预留 `opts[:backend_profile]` —— #1449 PR-4 会填
- [ ] `record_unfilled_role_slots` + telemetry：
  - `:telemetry.execute([:ezagent, :agent, :role_slot_skipped], %{count: 1}, %{role_name: ..., reason: reason_tag(reason), raw_reason: inspect(reason)})`
- [ ] `reason_tag` 细化：`:no_credential_source` → `:missing_claude_credentials`（当 flavor=cc且 source 链归 NONE）；`:credential_unavailable` → `:failing_environment_credential`（env-backed flavor 的 key 不可用时）；其他保持 `:unavailable`
- [ ] 测试：
  - skip telemetry 断言（`:telemetry.attach_many` handler 收事件）
  - reason 类别区分 test（admin installer vs non-admin + 无 workspace-shared → `:missing_claude_credentials`；env-key flavor 缺 key → `:failing_environment_credential`）

### PR-4 — gate + 回归 + e2e
- [ ] `mix test` affected apps（ezagent_domain_agent, ezagent_domain_session）+ format
- [ ] `mix ezagent.check_invariants` / `arch.scan` / `doc.scan` / `uri_query.scan`
- [ ] `mix ezagent.check_invariants.lifecycle`（如有新 Behavior 代码）
- [ ] e2e（复用任务 A 的隔离栈模式）：
  - 无凭证建会话 → 断言 assistant skip（`unfilled_agent_role_slots` 有 `:missing_claude_credentials`）
  - operator 配凭证（PR-1 CLI）→ 补物化（PR-2 CLI）→ assistant 进成员、skip 行清
  - **不要求 UI 横幅**（zyli 侧），以数据库断言为准

## 2. 约束
- #1449 PR-4 会改 `credential_precondition.ex`——PR-3 采用 `opts \\ []` 签名、保留 `check_source/3` 向后兼容，PR-4 只需加 `opts[:backend_profile]` 分支
- 凭证写入走 sanctioned dispatch/CLI task，不 raw DB（`cap_check_only_at_chokepoint`）
- 不实现"凭证配置 UI"——v1 只做 operator CLI（handoff §4 "可先只做 operator 路 + 文档"）
- 任务 A 发现的"kind: :any cap 补发面缺失不在此修，记 follow-up

## 3. codex #3/#4 纳入但不修（记 return）
- **#3 token 生命周期**（每次 mint 永不过期、不随 sidecar 撤销）：PTY + headless 同病，修法要 token row id 持有→终止撤销，不改在此任务
- **#4 token 暴露面**（经两层 env 传给所有子进程）：凭证代理/wrapper 属更大设计，不改在此任务
- 两条都写进 return 的 "method friction / follow-up" 节，不阻塞 merge
