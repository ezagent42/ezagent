> **Task:** share-A2-2 codex 修复 — H1(funnel 完整)+ H2(grantees_of caller 授权)
> **Branch:** `feat/socialware-share-a2-grantees`
> **PR:** #1606
> **Dev:** jjkysy (agent)
> **returned_at:** 2026-07-28 20:20 +0800
> **deadline_status:** on_time

## 做了什么(codex H1 + H2)

**H1 — funnel 完整(接回两个旁路写口)**:codex 指的两个绕过 `persist_entity_caps`(GranteeIndex.reindex hook 所在)的写口,正是我在 A2-2 原 return 里自标的两条漏网:
- `handle_revoke_cap`(`:revoke_cap` action)—— 原来只发 `set_caps_effect`,现在先 `persist_entity_caps(receiver, new_caps)` → reindex 反映撤除。
- `handle_sync_recipe_binding`(recipe reconcile)—— 同,接进 funnel。
现在**所有** cap-mutation handler(absorb/grant/persist/store/remove/**revoke**/**sync**)都过唯一漏斗,index 不再与真相发散。(撤销 generation FILTER 本就正确 ✓。)

**H2 — grantees_of caller 授权**:原 `grantees_of(target, behavior)` 无 caller 授权 → 任何 in-VM caller 知道 target URI 就能枚举 grantee。现在 `grantees_of(target, caller, behavior)`:只有**管理 target 的 caller**(`Ezagent.Identity.Authority.manages?/2` —— data_owner / admin / workspace-admin)能枚举,其它 caller → `[]`(fail-closed)。知道 URI 不等于有权看它分享给了谁。

## DoD reconciliation
| # | DoD line | status | proof |
|---|----------|--------|-------|
| 1 | H1 revoke_cap 接进 funnel(reindex 反映撤除)| met | grantee_index_test reindex 用例 6/0 |
| 2 | H1 sync_recipe_binding 接进 funnel | met | identity 行为回归 33/0(sync handler 不破)|
| 3 | H1 不破 revoke/sync 现有行为 | met | identity_absorb/grant/identity 行为 33/0 |
| 4 | H2 授权 caller(管理者)能枚举 | met | grantee_index_test H2 用例:admin 见 grantee |
| 5 | H2 非授权 caller → [](fail-closed)| met | H2 用例:stranger → [] |
| 6 | grantees_of 签名变更无 blast radius(无生产调用者)| met | grep `apps/*/lib` 零调用者 |
| 7 | arch 闸(cap_absorb/Z-1 ratchet/doc/cross_file)| met | cap_absorb 6/0 · Z-1 ratchet 7/0 · doc_coverage 17/0 · cross_file 1/0 · format clean |
| 8 | full suite CI 绿 | pending | push 后 CI |

## 关键决策
- **H2 fail-closed 返 []**(而非 `{:error, :unauthorized}`):保持返回类型 `[URI.t()]`,未授权 caller 看不到任何 grantee(枚举语义的 fail-closed);不区分"无 grantee"与"无权"对枚举是安全默认。
- **H2 授权谓词 = `Authority.manages?`**:复用现成的"caller 是否对 target 持管理/owner 授权"判定(含 admin/workspace-admin union),不新造授权机制。
- 测试用 canonical admin 作授权 caller(测试 target 无 recorded owner,admin manages all)+ 加 stranger 负向用例。

## Merge request
codex H1+H2 修复,PR #1606。与 A1 M1/M2、A2-1 H3、A3 M3/M4 并行。`:members` 投影(A4-2)将是 grantees_of 的首个消费者,届时传 session-owner 作 caller。
