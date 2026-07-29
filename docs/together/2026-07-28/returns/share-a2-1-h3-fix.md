> **Task:** share-A2-1 codex 修复 — H3(caps_toward 对齐 current-generation)
> **Branch:** `feat/socialware-share-a2-visibility`
> **PR:** #1596
> **Dev:** jjkysy (agent)
> **returned_at:** 2026-07-28 19:40 +0800
> **deadline_status:** on_time

## 做了什么(codex H3)
`Cap.Visibility.caps_toward/2` 原来只按 behavior+instance 纯过滤,不验当前 generation → 被撤销(generation-bumped)的 cap 前向仍"可见",而反向 `grantees_of` 正确隐藏 = 前后不一致(codex H3)。

- `caps_toward/2` 现在**加 current-generation 过滤**:每个候选 cap 的 `key_id` 必须等于其 target 当前 active authority 的 `key_id`(`KindCapAuthority.active`),否则排除。镜像反向 `grantees_of` 的同款过滤 + dispatch 咽喉的 current-gen 校验。unsigned/legacy(无 key_id)cap 永不算 current。
- 每个不同 target 一次 authority 读(moduledoc 已注明代价)。授权咽喉仍是 `Cap.authorize/3`,本函数只枚举(超集便利,非授权)。

## 关键决策
- **不再是纯函数**:原 moduledoc「pure, no store」是 codex 指的病灶(展示已撤销 cap)。改为 store-backed 的 current 验证,与 grantees_of/dispatch 对齐。moduledoc 已改述。
- **无生产调用者**:caps_toward 是 additive(各 biz 尚未迁入),grep 确认 `apps/*/lib` 零调用者 → 行为变化无 blast radius。
- **测试重写**:原测试用未签名构造 cap(无 key_id/authority),加 gen 检查后会被全排除 → 改用真签发 cap(`Authority.open` + `CapHelper.authority_signed_cap_as!`,同 grantee_index_test),并加两个 H3 用例(regenesis 后撤销 cap 消失 / unsigned cap 不 surface)。

## DoD reconciliation
| # | DoD line | status | proof |
|---|----------|--------|-------|
| 1 | caps_toward 排除 stale-generation(撤销)cap | met | `visibility_test` H3 用例:regenesis 后 = [] |
| 2 | 与 grantees_of 反向索引一致 | met | 同款 key_id==active 过滤 |
| 3 | unsigned cap 不 surface | met | H3 unsigned 用例 |
| 4 | 现有语义(behavior 过滤/去重/:any 排除/MapSet)保持 | met | visibility_test 6/0 |
| 5 | 无 verify_against_current 字面(Z-1 ratchet)| met | grep CLEAN |
| 6 | arch 闸 | met | doc_coverage 17/0 · cross_file 1/0 · format(根验)|
| 7 | full suite CI 绿 | pending | push 后 CI |

## Merge request
codex H3 修复,PR #1596。与其它 codex 修复(A1 M1/M2、A2-2 H1/H2、A3 M3/M4)并行。
