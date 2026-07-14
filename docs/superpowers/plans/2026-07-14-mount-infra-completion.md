# #1376 补完：通用挂载 infra 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development 逐任务实施。步骤用 `- [ ]`。

**Goal:** 把 #1376 从「只有 `mint_cap` 原语」补成完整通用挂载 infra——运行时挂载(pull/forward/create)落一张挂载表(真相源)、reconcile 读表重发(session 重建存活)、installation 加 socialware 收尾触发 reconcile(闭合 X-fix)。所有 sw 复用同一套通用 Mount API,kanban 只是消费者。

**Architecture:** 缺口 = `mint_cap/4`(composition_caps.ex:140)复用 `issue_item`+`absorb_one`(I12 唯一 absorb chokepoint)但刻意不写表,故运行时挂载无 SoT。补法 = 新建 `socialware_mounts` 表(B1,不碰声明式 `replace_session`,照 `external_mirror_bindings`/`CompositionBinding` 先例)+ 通用 `Ezagent.Socialware.Mount` API(mint_cap + 落表)+ reconcile 读表重发。

**Tech Stack:** Elixir/Ecto(domain_session/socialware);composition 车道 = **pg-only**(migration 只在 `priv/repo_pg/`)。

## Global Constraints
- 工具链:tracked `.tool-versions` = elixir 1.19.x-otp-28 / erlang 28.x;跑 mix 用它,不用 mise OTP27。
- TDD;不撞 gate(I12 `cap_self_store_paradigm_lock` / p6 `CapCheckOnlyAtChokepoint` / arch baseline)。**M1-M3 不得新增第二个 absorb 点**——挂载重发仍走现成 `mint_cap`→`absorb_one`(I12 唯一 absorb)。
- 分支 `feat/composition-runtime-grant`(#1376)。挂载表 SoT = 表本身(非 slice projection),照 `CompositionBinding`(table-as-SoT)。
- behavior/role/actions 全参数化,Mount API 零 kanban 专属字面(board/kanban-assistant/get_tree 都由调用方传)。

---

## Task M1: `socialware_mounts` 挂载表 + 行操作

**Files:**
- Create: `apps/ezagent_core/priv/repo_pg/migrations/<ts>_create_socialware_mounts.exs`
- Create: `apps/ezagent_domain_session/lib/ezagent/socialware/mount_row.ex`(Ecto schema + CRUD,与 `composition_binding.ex` 同层)
- Test: `apps/ezagent_domain_session/test/ezagent/socialware/mount_row_test.exs`

**Interfaces:**
- Produces: `MountRow.upsert(attrs)` / `list_for_session(session_uri)` / `delete_by_natural_key(session_uri, target_uri, grantee_uri, behavior)` / `mount_id(session_uri, target_uri, grantee_uri, behavior)`(session-scoped SHA256, 抄 `BindingRow.row_id/3`)。
- 列:`id`(PK string hash)、`session_uri`、`target_uri`(数据宿主 agent)、`grantee_uri`(持钥匙者,如 assistant)、`behavior`、`actions_json`(授予的动作集)、`access`(:read|:operate)、`granted_by`(=target data_owner)、`workspace_uri`、`mounted_at`。unique index `(session_uri, target_uri, grantee_uri, behavior)`。

- [ ] Step 1: 写失败测试 —— `MountRow.upsert` 一条 → `list_for_session` 读回;同自然键再 upsert → 覆盖不重复;`delete_by_natural_key` 删除;`mount_id` 同参稳定、跨 session 不撞。
- [ ] Step 2: 跑测试确认失败。
- [ ] Step 3: 建 migration(pg-only)+ schema + CRUD(照 `mount_row.ex` interfaces)。
- [ ] Step 4: `mix ecto.migrate`(pg)+ 测试通过。
- [ ] Step 5: I12 + p6 探针绿(没引入新 absorb / cap 读)。`mix format` + commit。

## Task M2: 通用 `Ezagent.Socialware.Mount` API

**Files:**
- Create: `apps/ezagent_domain_session/lib/ezagent/socialware/mount.ex`
- Test: `apps/ezagent_domain_session/test/ezagent/socialware/mount_test.exs`

**Interfaces:**
- Consumes: `CompositionCaps.mint_cap/4`(唯一 mint chokepoint)、`MountRow`(M1)、`Workspace.create_agent`、`CapabilityRegistry.data_owner_of`。
- Produces:
  - `mount(session_uri, target_uri, grantee_uri, behavior, actions)` → `mint_cap` + `MountRow.upsert`。access 由 actions 判(全动作=:operate / 只读子集=:read)。
  - `unmount(session_uri, target_uri, grantee_uri, behavior)` → 撤 cap(`Identity.Grant.revoke_cap`)+ `MountRow.delete_by_natural_key`。
  - `provision(session_uri, workspace_uri, spec, grantee_uri, behavior, owner_ctx)` → `Workspace.create_agent` + `mount`(= create_board 泛化;spec 带 role/flavor/name)。

- [ ] Step 1: 写失败测试 —— `mount` 后 grantee 持 cap 且挂载表有行、`dispatch` 只读/操作按 actions 成/拒;`unmount` 后 cap 撤 + 行删;`provision` 建宿主(data_owner=owner)+ 当场挂。用通用 test 靶 behavior(复用 `composition_grant_target_behavior.ex`,非 kanban)。
- [ ] Step 2: 跑测试确认失败。
- [ ] Step 3: 实现 Mount(全参数化,零 kanban 字面)。
- [ ] Step 4: 测试通过 + I12/p6 探针绿。`mix format` + commit。

## Task M3: reconcile 读表重发 + installation 收尾触发(X-fix)

**Files:**
- Modify: `apps/ezagent_domain_session/lib/ezagent/socialware/composition_caps.ex`(加 `reconcile_mounts(session_uri)`:读 `MountRow.list_for_session` 逐条重跑 `mint_cap`)或放 `mount.ex`
- Modify: `apps/ezagent_domain_session/lib/ezagent/socialware/installation.ex:227,247`(`install_template_installs`/`repoint_template_installs` 收尾触发 reconcile,对称卸载侧 `retract_session_installs:191` 的 `deactivate_session`)
- Modify: session 重启/activate 路(`ActionSet.Session.Reconcile.reconcile_after_load` 或 Session Kind activate)调 `reconcile_mounts`
- Test: `apps/ezagent_domain_session/test/.../mount_reconcile_test.exs`

**Interfaces:**
- Consumes: `MountRow.list_for_session`、`mint_cap`。
- Produces: session 重建后运行时挂载存活(cap 重发);加 socialware 到已存在 session 触发 reconcile(declared edge 也补发)。

- [ ] Step 1: 写失败测试 —— (a) mount 一条 → 模拟 session 重启(清 holder cap slice / 重跑 activate)→ 断言 cap 经 `reconcile_mounts` 重现;(b) 往已存在 session install 一个带 operates 的 socialware → 断言 composition cap 被 reconcile 发出(现在不会)。
- [ ] Step 2: 跑测试确认失败。
- [ ] Step 3: 实现 `reconcile_mounts` + installation 收尾触发 + activate 挂钩。**declared reconcile(`replace_session`)不动**——runtime mount 独立表、独立 reconcile,互不 inactivate。
- [ ] Step 4: 测试通过 + I12/p6/arch baseline 全绿。`mix format` + commit。

---

## 后续(不在本计划,在 #1374)
- `BoardProvision` 塌缩成 `Mount` 消费者(传 kanban-board behavior / `kanban-assistant` role / `[:get_tree,:export_markmap]`);T6 触发器接 `Mount` API。

## Self-Review
- 覆盖 Allen handoff:挂载表(M1)+ 触发器/生命周期(M2)+ reconcile 打通含 X-fix(M3);通用 sw 复用(Mount API 零 kanban 字面)。
- 不碰 I12 唯一 absorb(重发走 mint_cap→absorb_one);不动声明式 `replace_session`(B1 独立表)。
- 类型一致:`MountRow`(M1)被 M2/M3 消费;`Mount.mount`(M2)被 M3 reconcile 复用。
