> **Task:** share-A1 codex 修复 — M1(issuer 授权)+ M2(URI-kind-agnostic)+ D2a(allow_anon 契约)
> **Branch:** `feat/socialware-share-a1-token`
> **PR:** #1594
> **Dev:** jjkysy (agent)
> **returned_at:** 2026-07-28 21:20 +0800
> **deadline_status:** on_time
> **note:** D2 反转 —— 查实 anon 访问已有 `web_anon_access`(publish session)机制;share link 保持 person-only(person-cap),撤掉 D2a 的 allow_anon,anon 不进 share 路。见文末。

## 做了什么(codex M1 + M2 + D2a)

**M1【CRITICAL】—— 令牌绑定 + 双端校验 issuer 授权**:
- `ShareToken` 载荷加 `issuer` 字段(MAC-bound);`mint_link!/4`→`mint_link!/5`(issuer 首参);`verify_link` 返回带 issuer。
- 新 domain 生产者 `Ezagent.Socialware.Share.mint_link/5`:签发前验 `issuer == target 的 data_owner`(Allen D1「granter ≡ data_owner」),不授权不签。
- `Share.claim/2`:验签后**再验** issuer 仍是 target **当前** data_owner(撤销/转移则作废),再 mint。→ 服务器签名 token 不再能授出创建者没有的权限。

**M2【CRITICAL】—— URI-kind-agnostic**:
- `CompositionCaps.mint_cap`:从硬编码 `kind: :agent` 改为**从 target URI 推导 kind**(`target_kind/1`,entity→:agent / session→:session / resource→:resource),untyped/unknown fail-closed。session://、resource:// token 不再签出"能验签但 kind 不匹配、无法授权"的假 cap。
- `Share.claim`/`mint_link` 加 conformance 校验:用 **kind-agnostic** `Ezagent.Kind.resolve_action_subject/2`(在 target actor 内解析处理该 action 的 behavior,任意 Kind)验 target 确实处理声明的 behavior/actions,否则拒。

**D2a —— per-share allow_anon 策略位**:`ShareToken` 载荷加 `allow_anon`(默认 false 安全默认),`mint_link!` opt;业务声明"是否允许匿名领取",平台只承载 + 校验。

## DoD reconciliation
| # | DoD line | status | proof |
|---|----------|--------|-------|
| M1 | token 带 issuer + claim 验 issuer==当前 data_owner | met | share_test:M1 attacker→`:share_issuer_not_data_owner`;Share.mint_link 生产者拒非 owner |
| M1 | 结构性(生产者 + claim 双端)非"记得检查" | met | Share.mint_link 签发 gate + claim re-verify |
| M2 | kind 从 URI 推导(非硬编码 :agent)| met | mint_cap target_kind;composition 回归 17/0 |
| M2 | claim 路 conformance(kind-agnostic)| met | share_test:M2 非 conformant→`:share_target_not_conformant` |
| D2a | per-share allow_anon 位(默认 false)| met | share_token_test 9/0(allow_anon 载荷)|
| 6 | 现有 happy-path 不破 | met | share_test 7/0 · share_token 9/0 · claim_controller mint_link! 已适配 |
| 7 | arch 闸 | met | Z-1 probe 字面 CLEAN · format clean · cross_file · composition 回归 17/0 |
| 8 | full suite CI 绿 | pending | push 后 CI |

## 待定 —— D2b(anon 控制器物化)
Allen D2 要"anon 访客先物化只读 anon entity 再走同一 claim"。**撞设计岔路**:现成 anon 机制(`AnonUser`/`AnonCookie`)是 **session-bound**(cookie 签 `(anon, session)`),但 share target 是任意 URI 无 session → anon 领取后要能被下次请求认出需 **session-less anon cookie = 新 web 安全代码**(CLAUDE.md:非 caps 安全机制加之前先确认)。三选项 A(泛化 cookie session-less)/ B(给 anon 落地 session)/ C(A1 只做 mint+allow_anon 门,cookie/看分享物归紧邻后续件)提给 PO。**M1/M2/D2a 是本 PR 的安全关键 + 策略契约,先合;D2b 定后补。**

## Merge request
codex M1/M2/D2a 修复,PR #1594。与 A2-1 H3、A2-2 H1/H2、A3 M3/M4 并行。D2b 等 PO 决策。
