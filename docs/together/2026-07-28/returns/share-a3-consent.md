> **Task:** share-A3 — URI-share owner-consent(泛化 CompositionConsent 的宽松特例)
> **Branch:** `feat/socialware-share-a3-consent`
> **PR:** https://github.com/ezagent42/ezagent/pull/1597
> **Dev:** jjkysy (agent)
> **returned_at:** 2026-07-28 12:20 +0800
> **deadline:** 2026-07-28 (Group A 推进)
> **deadline_status:** on_time

## 做了什么
URI 授权分享统一(#1583 §7)的审批件。**把现有 composition-consent 机制泛化成宽松超集**,URI-share 是其中"一方审批"的特例;composition 的两方审批变成受约束的特例,复用同一张表 + 同一套状态机 + 同一个 owner 待办箱。additive,纯 domain_session + 一个 core migration,零业务/kanban 文件。

- **migration `20260728000000_generalize_composition_consent_uri_share`**:把 `socialware_composition_consents.binding_id` 与 `..._commands.binding_id` 从 NOT-NULL 放松为 NULL-able;consents 加 `target_uri`/`grantee_uri` 两列(URI-share 无 binding 时的直接寻址),commands 加 `consent_id`(直挂 consent、不经 binding)。composition 老行 binding_id 照旧非空、语义不变。
- **`Ezagent.Socialware.CompositionConsent` 泛化入口**:
  - `request(target, grantee, behavior)` — 宽松件。binding_id=nil,target_owner=data_owner_of(target),`source_approval: :approved` **自动满足**(申请人=接收方,源方无需自审),按 `(target,grantee)` 确定性键幂等。
  - `decide(id, :approve|:deny, actor, key)` — 从 `consent.target_owner_uri` 认证 actor(非 owner→`:consent_actor_not_target_owner`),复用状态机 transition + 幂等 command log + replay。无 binding、无 session 依赖。
  - `approved?/3`、`pending_for_owner/1` 复用同一 owner 待办箱。
- composition 的 `sync`/`command`/schema **行为零改动**(只是 schema 多了两个 nullable 列 + 一个 nullable FK);两方 binding 路径仍是那条受约束特例。
- per_tenant 不变量:consents/commands 登记不变(表名没变,只是加列)。

## 关键决策(xy 查证 — 推翻上一版 sibling 方案)
第一版按"两方 vs 一方语义不同 + binding_id 是刻意 NOT-NULL 耦合"→ 建了 sibling `share_consents` 表。**PO(Allen/用户)校准**:URI-share 本就是 composition-consent 的**宽松超集**(composition = 两方都要审批的受约束特例;URI-share = 源方自动满足的宽松件),应当**泛化复用现有机制**,而非并列重造一套状态机 + 待办箱(否则 kanban rule-8 迁移时两套并存会 drift)。故推翻 sibling:放松 binding_id 约束、加直接寻址列,composition 降级为"binding 非空 + 两方"的特例。这也让 Group B 的 kanban rule-8 只需迁到**这一个** seam。

## DoD reconciliation
| # | DoD line | status | proof |
|---|----------|--------|-------|
| 1 | request(无 binding)→owner approve→approved?(:target) true;deny→false | met | `composition_consent_uri_share_test.exs` test 1+2 |
| 2 | 非 owner 拒(`:consent_actor_not_target_owner`);target 无 owner fail-closed | met | test 1 + test 4 |
| 3 | 幂等:request 按 (target,grantee) 去重;decide 同 key replay 不重复 transition | met | test 3 |
| 4 | composition 两方 sync/command/binding 路径回归不破 | met | composition_grant/binding/caps **20/0** |
| 5 | 零 kanban/业务;本地 format+doc_coverage+per_tenant+cross_file | met | 见下 gate 状态 |
| 6 | full suite CI 绿 + Loop C | pending | push 后 CI run(见下) |

**Method friction:** sibling→泛化的返工根因 = plan 阶段把"两方/一方语义差异"当成了"必须两套机制",没先问 PO"宽松超集能不能复用原机制"。教训:当新需求是既有机制的**宽松/收紧变体**时,默认假设是"泛化同一机制",要先证伪(为什么不能复用)再另起炉灶,而不是反过来。碰 schema 约束(NOT-NULL FK)时,泛化 = 放松约束 + 加旁路列,通常比新建表更省后续迁移。

## 分支 + gate 状态
- Branch rebased onto `main` @ `b9daedefe`。
- 本地闸(全绿):
  - A3 泛化功能:`composition_consent_uri_share_test.exs` **4/0**
  - composition 回归:grant+binding+caps **20/0**
  - per_tenant **88/0**、doc_coverage **17/0**、cross_file(见 push 后确认)、format clean
- CI:push 后重跑的 run URL(本 return + 泛化最终 HEAD)。

## Merge request
PR #1597,Group A 独立件(与 A1 #1594 / A2-1 #1596 并行,互不依赖)。建议 lead 待 CI 绿后并入 main。

## 遗留 / 开放决策
- 无 deferred DoD。
- 消费者迁移(kanban 手搓 rule-8 审批 → 迁到本泛化 seam)= Group B,不在本 PR。
