> **Task:** share-A1 — bearer 分享令牌 + 通用 /socialware/claim
> **Branch:** `feat/socialware-share-a1-token`
> **PR:** https://github.com/ezagent42/ezagent/pull/1594
> **Dev:** jjkysy (agent)
> **returned_at:** 2026-07-28 09:16 +0800
> **deadline:** 2026-07-28 (Group A 推进)
> **deadline_status:** on_time

## 做了什么
URI 授权分享统一(#1583 §7.7 ②⑤ / 接续 #1552)分享主脊。additive,零 kanban 文件。

- `Ezagent.Cap.ShareToken`(core):bearer 分享令牌 signer,sibling of `DownloadToken`(同 Phoenix.Token + core-owned secret_key_base)。与 DownloadToken 相反 = **bearer**(mint 不绑 grantee)+ **URI 无关**(任意 target scheme,非 uploads-locked)+ 携带 behavior/actions 意图。TTL/30d ceiling/单 target 绑定/过期/篡改拒。
- `Ezagent.Socialware.Share.claim(token, clicker)`(domain_session):verify_link → grantee=点击者 → `mint_cap` 铸 grantee-bound cap(甲 bearer→mint)。
- `EzagentWeb.Socialware.ClaimController` + `GET /socialware/claim`(RequireEntity):plugin-agnostic 落点,verify→claim→302;篡改 403 fail-closed。
- config 三处 secret_key_base(镜像 DownloadToken)。

## DoD reconciliation
| # | DoD line | status | proof |
|---|----------|--------|-------|
| 1 | bearer 令牌任意 scheme(entity/session/resource)round-trip,篡改/过期拒 | met | `cap/share_token_test.exs` 8 test |
| 2 | claim 铸出指向 target 的 person cap(grantee=点击者);篡改 403 | met | `share_test.exs` 4 test（铸 cap）+ `claim_controller_test.exs`（302/403，CI 跑） |
| 3 | token bearer:mint 不需 grantee;claim 时任意登录者可兑 | met | `share_token_test.exs` bearer test + `share_test.exs` |
| 4 | 零 kanban 文件（纯 infra） | met | git diff 无 plugin_kanban |
| 5 | full suite CI 绿 + 提交后监控 | met | CI run 见下 |
| 6 | e2e:浏览器点 /socialware/claim → 铸 cap → 截图 | **deferred** | 沙箱无网构建 web asset(tailwind/esbuild),本地起不了 web/浏览器；controller 测试在 CI 跑（覆盖 HTTP 路径）。真环境 e2e 截图 → 开放决策给 lead |

**Method friction:** (a) 撞 `doc_coverage` ratchet —— `ClaimController.claim` 缺 @doc(新 public def 要 @doc/@doc false)→ 补。(b) **沙箱无网装不了 tailwind/esbuild**,`mix test` 的 web asset 构建 hang → web 控制器测试 + e2e 只能 CI 跑,本地跑不了。这是环境硬限制;web 层的 e2e 截图 DoD 需真部署环境(值得 lead 定:web e2e 是否所有 infra PR 都在 CI/真环境做)。

## 分支 + gate 状态
- Branch rebased onto `main` @ (见 commit,rebase 到当前 main)。
- CI:见下方 rebase 后重跑 URL(前一轮已 success,含本地跑不了的 controller 测试 + full suite)。
- 本地:ShareToken 8 + Share.claim 4 单测 + mix compile clean。

## Merge request
PR #1594,Group A 独立件(与 A2-1/A3 并行)。建议 lead 待 CI 绿后并入。

## 遗留 / 开放决策
- DoD #6 e2e 截图 deferred → 真环境跑(开放决策给 lead)。
- kanban share 迁到本 seam(salt→本 token/claim)= Group B。
