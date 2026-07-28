> **Task:** share-A3 codex 修复 — M3(审批认证+绑定)+ M4(migration shape 不变量)
> **Branch:** `feat/socialware-share-a3-consent`
> **PR:** #1597
> **Dev:** jjkysy (agent)
> **returned_at:** 2026-07-28 21:00 +0800
> **deadline_status:** on_time

## 做了什么(codex M3 + M4)

**M3 — 审批认证 + 当前 owner + 绑定 behavior/actions**:
- **① authenticated requester**:`request/3`→`request/4`,`grantee` 参数改名 `requester` 且 doc 明确它 MUST 是**认证的调用者**(transport 传 authenticated principal,不是 client 供的任意 grantee)——否则任何人能替第三方伪造"接收方同意"。source 侧 attestation 因此不可伪造。
- **② 当前 owner**:`decide` 的 `apply_decide` 原来按建单时存的 `target_owner_uri` 验 actor;现在 **re-resolve target 的当前 data_owner**(`current_target_owner/1` 从 consent 存的 behavior+target_uri 重解析)再验。target 转移/换主后必须由**现任** owner 批,旧 owner 不能批。
- **③ 绑 behavior/actions**:consent 原来身份只有 `(target, grantee)`;现在存 `behavior` + `actions_json`(request/4 带 actions,空 actions 拒 `:invalid_consent_request`),一次批准不能覆盖比申请更宽的权限。

**M4 — migration exactly-one-shape 不变量**:
- migration 加 DB **CHECK constraint** `consent_binding_xor_uri_share`:一行 EITHER composition(binding_id 有、target/grantee 无)XOR URI-share(binding 无、target+grantee 有)。
- changeset 加 `validate_shape/1`(insert 前 fail-loud,镜像 DB CHECK)+ `check_constraint`。
- migration 加 behavior/actions_json 列(M3③ 需);down 对称回滚。

## DoD reconciliation
| # | DoD line | status | proof |
|---|----------|--------|-------|
| M3① | requester 认证契约(source attestation 不可伪造)| met | request/4 rename+doc;source_owner=认证 requester |
| M3② | decide 按 target 当前 owner 验(非建单时旧 owner)| met | apply_decide 用 current_target_owner;URI-share 6/0 |
| M3③ | consent 绑 (behavior, actions);空 actions 拒 | met | M3 用例:behavior/actions_json 存 + 空 actions→invalid |
| M4 | binding XOR uri-share:DB CHECK + changeset validate | met | migration CHECK 应用 + validate_shape;composition 回归 20/0 |
| 5 | composition 两方路不破(shape 不误伤)| met | composition grant+binding+caps 20/0 |
| 6 | arch 闸 | met | doc_coverage 17/0 · cross_file 1/0 · format clean |
| 7 | full suite CI 绿 | pending | push 后 CI |

## 关键决策
- **current_target_owner 对 composition 行回落存 owner**:composition consent 无直接 behavior/target(其 owner 授权走 binding),故回落 `target_owner_uri`;URI-share 行(有 behavior+target)才 re-resolve。两路都对。
- **behavior 存 `inspect(module)`**(无 Elixir. 前缀)+ `Module.concat` 解回,同 Mount actions_json 约定。

## Merge request
codex M3+M4 修复,PR #1597。与 A1 M1/M2、A2-1 H3、A2-2 H1/H2 并行。注:migration 改动(加 CHECK+列)——rebase 后 dev/e2e 前需 `mix ecto.reset`(应用新 migration)。
