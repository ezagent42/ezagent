# Re-route Phase 1-3 执行 plan(post-recon,基于 #814 合并树实测)

**日期:** 2026-06-17
**前置:** [re-route plan](./2026-06-17-admin-ui-reroute-implementation-plan.md) · [main-sync recon](./2026-06-17-main-sync-recon-findings.md)
**实测基准:** scratch 合并树 `autoservice-dev + origin/main`(含 #814 `Ezagent.Identity.Grant`)

---

## 现状(侦察后修正)

re-route 比 assessment 预想的**更靠后** —— Phase 0 + Phase 1 的脚手架大半已在:

| Phase | 原以为 | 实测 |
|---|---|---|
| 0 — ContentAdmin dispatch 面 | 要新建 | **已铺满 16 action**(`fix/content-and-mechanical`),A5 干净 |
| 1 — 给 admin 授 content cap | 要从头写 | **`roles.ex` 已在授**(`:admin` bundle),只差一个 kind-axis bug |
| 2 — UI 改走 dispatch | 主要工作 | **仍是主要工作**(UI 仍 `File.write` + `can_write?` 洞) |

关键实测点:
- `tenant_admin_live.ex:39` **已经** `_caps = Ezagent.Identity.list_caps_for(admin_uri)` —— 取了 caps 却丢弃,L40 仍 `can_write? = admin_uri != nil`。修洞的脚手架现成。
- `Ezagent.Identity.Grant.grant_cap_effect(target, cap, authorization) :: {:dispatch, Cmd.t()}` —— Behavior handler 返回 effect 用;authorization 用 `{:held_by, granter}` / `{:rule, name, configurer}`(`{:system,…}` 是 transitional)。
- kind 轴约定:**kind == 目标 Kind 的 scheme**。Workspace / WorkspaceUserAdmin(都挂 workspace Kind)的 required_caps 都用 `cap(:workspace, …)`,roles 也授 `:workspace`。ContentAdmin 也挂 workspace Kind → 同样该是 `:workspace`。

---

## Phase 1 — 让已有的 admin 授予真正生效(小修,ours)

**问题:** `roles.ex:56-57` 授的是 `grantable(:content, ContentAdmin, …)`(kind=`:content`),但 ContentAdmin.required_caps 是 `cap(:workspace, ContentAdmin, …)`(kind=`:workspace`)。CapBAC 按 kind 轴字面匹配 → **现授予永不匹配**(被"UI 从不 dispatch"掩盖)。且 L56 的 action `:write` 不对应任何 action(无名为 `:write` 的 action),只有 L57 的 `:any` 真正起作用。

**改:** `roles.ex` `:admin` bundle 的两行合并为
```elixir
grantable(:workspace, EzagentPluginContent.Behavior.ContentAdmin, :any, workspace_uri, now)
```
`:any` 在 action 轴通配,一个 cap 即授权全部 16 个 ContentAdmin action(kind/behavior 匹配 + action :any)。

**验:** 单测 —— `Roles.bundle(:admin, ws)` 里的 cap 应 `satisfies` 每个 `ContentAdmin.required_caps[action]`。

> 与 #814 chokepoint 不冲突:`bundle/2` 产出的是 `User.default_caps` 附着的 cap 结构,不是 `grant_cap` dispatch,不受 grep gate 约束。

---

## Phase 2 — UI 改走 dispatch + 删 `can_write?` 洞(主体工作,caps-dependent)

### 2a. 关洞
`tenant_admin_live.ex` mount:把 `can_write? = admin_uri != nil` 换成用**已取的** caps 判定 —— 持有满足任一 ContentAdmin required_cap 的 cap(即 `:workspace ContentAdmin :any` 或具体 action cap)才 `can_write?`。`list_caps_for/1` 已在调,不增 DB 读。

### 2b. 写事件改走 dispatch
每个写 `handle_event` 从「`if can_write? do File.write…`」改为「dispatch ContentAdmin action」。target = `Ezagent.URI.with_action(workspace_uri, :content_admin, <action>)`,ctx.caps = admin 的 caps,mode `:call`,失败回 flash。

写事件 → action 映射(operators 除外,留 IdentityAdmin):

| UI handle_event | ContentAdmin action |
|---|---|
| `save_soul` | `write_soul` |
| `save_slots` | `write_slots` |
| `save_skill` / `skill_save` / `update_skill_content` | `write_skill` |
| `skill_create` / `new_skill` / `create` | `create_skill` |
| `skill_delete` / `delete_skill` | `delete_skill` |
| `kb_add` / `kb_add_manual` | `upsert_kb` |
| `kb_delete` | `delete_kb` |
| `kb_rebuild` | `rebuild_kb` |
| `kb_fetch_url` | `fetch_kb_url` |
| `kb_upload` / `consume_kb_uploads` | `ingest_kb_file`(LV 存临时文件→传 path) |
| `save_fast_prompt` | `write_fast_prompt` |
| `publish` / `step3_publish` | `publish_cr` |
| `revert` | `revert_item` |
| `rollback` | `rollback_version` |
| `add_operator` / `toggle_operator` / `disable_operator` | ⏸ IdentityAdmin(本 phase 不动) |

### 2c. 范围确认
`tenant_admin_live.ex` 之外,确认 autoservice 侧是否还有第二个 admin LV 做直接写(assessment 提到的大 LV),一并纳入或显式记录延后。

---

## Phase 3 — E2E + 验收

- VERIFICATION e2e:admin 登录 → 编辑 soul/skill/KB → publish → 客户会话见效,全程经 dispatch(telemetry 可见 ContentAdmin :start/:stop)。
- 无 cap 的非 admin 用户:写操作返回 `:unauthorized`(洞已关)。
- grep gate:UI 层不再有 `File.write` / `SkillStore.write` / `KbStore.*` 直接写(除经 ContentAdmin)。

---

## 依赖与边界

- **不阻塞 Phase 2 的:** Allen 的 #3.1(turn-adapter 第 17 principal)是 session-domain 的事,与 content cap 无关 —— Phase 1/2 可独立推进。
- **需 Allen / 真实 sync 后才落地的:** Phase 2 是 caps-dependent(要 admin 真持 content cap),且改 `autoservice-dev` 的 UI(佳哥的代码)—— 真实 rebase-to-main 完成 + Allen 对 §3 拍板后执行更稳,避免在 scratch 树上做大改后还要 replay。
- **Phase 1 的 roles.ex 小修** 风险低、纯 plugin、且修的是既有 bug,可先行。
