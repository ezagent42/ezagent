> **Task:** share-A2-2 — 反向索引 `grantees_of`(cap → 行派生只读索引)
> **Branch:** `feat/socialware-share-a2-grantees`
> **PR:** https://github.com/ezagent42/ezagent/pull/1606
> **Dev:** jjkysy (agent)
> **returned_at:** 2026-07-28 15:10 +0800
> **deadline:** 2026-07-28 (Group A 推进)
> **deadline_status:** on_time

## 做了什么
URI-share 统一授权(#1583 §7.2)的**反向索引**:统一的"某 target 的 cap 发给了谁"反查,收掉各 biz 各造(`:members` 今天在 biz 层手做)。additive,新表 + cap/identity 层新模块 + 一处 hook。**A4 的前置件**(A4-2 把 `:members` 投影到它)。

- **新表 `cap_grantee_index`**(repo_pg migration):`(target_uri, grantee_uri, behavior, action, key_id, granted_by, workspace_uri)`,自然键 `(target,grantee,behavior,action)`。≈ MountRow schema 去掉 session-scope/reconcile 包袱。
- **`Ezagent.EntityCaps.GranteeIndex`**(domain_identity,cap/identity 层):
  - `reindex(grantee, caps)` — 按 grantee 全量重索引(删该 grantee 旧行 + 从 new_caps 重插指向具体 target 的 cap);**授予和移除都覆盖**;`:any`/scope-tuple 通配 instance 不索引;best-effort(rescue,永不 break cap 存储)。
  - `grantees_of(target, behavior \\ :any)` — 按 target **当前 active authority key_id** 过滤,返回去重 grantee URI。
- **hook**:挂进 `persist_entity_caps/2`(behavior/identity.ex)——absorb/grant/persist/store/remove **五条 store 路的共享漏斗**,对 user 和 agent 都触发。
- per_tenant 登记:`cap_grantee_index` 进 `@per_tenant_schemas`(workspace_uri NOT NULL)。

## 关键决策(xy 查证)
1. **撤销=读时 generation 过滤,不删行**(handoff §7.2 模型):每行存 cap 的 `key_id`,读时比对 `KindCapAuthority.active(target).key_id`。`revoke_all_to` bump generation→active key_id 变→旧行自动失效。镜像 `verify_against_current/3`,**不引入新撤销机制**、不写撤销删除路。
2. **hook 点 = `persist_entity_caps` 而非 handoff 说的 `absorb_cap`**(调研纠正):`absorb_cap` 只是跨节点门面,真正的共享写漏斗是 `persist_entity_caps`(5 个 store handler 都过它)。挂它 + 全量重索引 → 授予**和移除**都覆盖(反向索引作为"当前谁持 cap"的投影必须反映删除)。覆盖边界:`handle_revoke_cap`(`:revoke_cap` action)与 `sync_recipe_binding` 两条不过 `persist_entity_caps`,靠读时 generation 过滤兜底撤销主路(`revoke_all_to`)——已在代码注释与本 return 标明。
3. **层 = cap/identity(domain_identity)**:纯 cap 索引下沉,挂 EntityCaps/absorb_cap 侧(Allen §7.5 "cap/identity layer")。表在 core repo_pg(与 MountRow 同模式:migration 在 core、schema 在 domain)。
4. **只出索引+接口,不迁 `:members`**:handoff §7.2 明确 `:members` 迁移碰 M-9 授权不变量、分两步;A4-2 才做投影。本 PR 是第一步。

## DoD reconciliation
| # | DoD line | status | proof |
|---|----------|--------|-------|
| 1 | absorb cap→grantees_of 列出 grantee + behavior 过滤 | met | `grantee_index_test.exs` test 1(5/0) |
| 2 | per-target 隔离;去重 | met | test 2 + test 5 |
| 3 | generation bump(revoke_all_to)自动失效旧行、不删 | met | test 3(regenesis 后 grantees_of=[]) |
| 4 | 移除 cap 反映(store 漏斗降集) | met | test 4 |
| 5 | 不破 cap 存储回归(改了 persist_entity_caps) | met | identity absorb/grant/entity_caps 39 过;3 个 `no_entity_host_handler` 失败=standalone 跑法坑,**干净 main 同样 3 失败**(已 stash 基线核实),非本改动 |
| 6 | per_tenant 登记正确 | met | schema 有 workspace_uri 字段 ✓ + DB 列 is_nullable=NO ✓ + 已登记 |
| 7 | 零 kanban/业务;本地 format+doc_coverage+cross_file+cap_absorb | met | doc_coverage 17/0 · cross_file 1/0 · cap_absorb_reachability 6/0 · format 5 文件 clean |
| 8 | full suite CI 绿 + Loop C | pending | push 后 CI run |

**Method friction:** 环境奇慢(冷 worktree 全 umbrella 编译因根 `mix test` alias 的 `pnpm install`〔无 skip 守卫〕撞沙箱无网络而假死 30min;逐 app 跑躲开但 `:umbrella_only` gate〔per_tenant〕又只能根跑)。绕法:core+domain_identity 逐 app 编译/测试;per_tenant 的实际断言(schema 字段/DB NOT NULL)用 `mix run` 直接查证代替跑框架;format 用根跑(不触发 pnpm alias)。教训:`:umbrella_only` gate 本地无法逐 app 跑时,直接验证它断言的事实是合规替代,full-suite CI 是最终权威。另:先写对文件名(cross_file 测试是 `_fn_test` 不是 `_groups_test`)+ 编译先跑完再跑单测,省得 mix 假死。

## 分支 + gate 状态
- Branch off `origin/main` @ `4c8b654f0`。
- 本地全绿(除 standalone 跑法坑,已核实非本改动)。
- CI:push 后 run URL。

## Merge request
Group A 反向索引件。**A1 #1594 / A2-1 #1596 / A3 #1597 已全绿 ready**;本件(A2-2)是 A4 的前置(A4-2 依赖 grantees_of)。建议 lead 待 CI 绿后并入 main;A4 在本件 + A2-1 合后开工。

## 遗留 / 开放决策
- `:members` 投影到 grantees_of = A4-2(碰 M-9,两步迁移的第二步),不在本 PR。
- drift gate(禁 biz 层再各自实现反向查询)= Group A 最后一件。
