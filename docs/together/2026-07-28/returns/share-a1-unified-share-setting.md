> **Task:** share-A1 重构 —— 统一分享模型(ShareSetting 资源开关),address M1 + D3
> **Branch:** `feat/socialware-share-a1-token`
> **PR:** #1594
> **Dev:** jjkysy (agent)
> **returned_at:** 2026-07-29 09:20 +0800
> **deadline_status:** on_time

## 做了什么

把 A1 从"token 带 issuer+意图"重构成**飞书式两层分享模型**,一举干净地解决 codex **M1**(授权凭证)+ **D3**(链接撤销),并把"分享"和"匿名"统一到一条开放度光谱上。

**两层解耦(飞书模型)**:
- **权限层 = cap**:谁持 cap 谁有访问。直接授权 + 已领取的协作者在这层,单独 `revoke_cap` 撤 / `grantees_of` 列。本重构不碰这层。
- **分享层 = 资源上一个开关**(新 `Ezagent.Socialware.ShareSetting`,per-target):owner 打开它才让"持链接的人自助获取 cap",并声明授什么。**授权凭证在这(只有 owner 能打开),不在链接。**

**具体**:
- 新表 `socialware_share_settings`(per-target)+ `ShareSetting` 模块:`enable/5`(验 owner==target 当前 data_owner)、`disable/2`(撤销)、`active/1`(claim 读)。`visibility` 枚举含 `link_login`/`link_anon`(超集光谱)。
- `Ezagent.Cap.ShareToken` **简化成无状态指针**(只签 target + TTL,不带 issuer/behavior/actions)。
- `Ezagent.Socialware.Share`:`enable`(+ M2 conformance)/`disable`/`mint_link`(纯指针)/`claim`(验签 → 读 target 的 ShareSetting → enabled 才按设置 mint,否则 `:share_disabled`)。
- per_tenant 登记 share_settings;claim_controller 无需改(`claim/2` 签名不变)。

## 怎么解决 M1 / D3 / M2

- **M1(授权凭证)**:"谁授权的" = **谁打开了资源的分享开关**(只有 data_owner 能),claim 查资源当前设置。取代 issuer-in-token——服务器签名的链接**本身不是授权**,没打开开关就 `:share_disabled`。测试:无 enable→拒 · 非 owner enable→`{:share_setting_not_target_owner}`。
- **D3(撤销)**:`disable/2` = owner 翻关一次,**该 target 所有在外链接立刻失效**(claim 读 `enabled:false`),已授权的 cap 不受影响(单独 `revoke_cap`)。测试:enable→c1 领到→disable→**同一链接** c2 领 `:share_disabled`,c1 的 cap 仍在。
- **M2(URI-kind-agnostic)保留**:mint_cap 从 URI 推导 kind(不变);conformance(kind-agnostic `resolve_action_subject`)移到 `enable`(owner 声明分享时验 target 真处理该 behavior)。

## 关于 anon(超集)
`ShareSetting.visibility` 含 `link_anon` 档(最开放),把匿名纳入同一开关的光谱。**匿名的实际机制是现成的 session 级 `web_anon_access`**(`PublicView`),所以 `link_anon` 的匿名 claim 路由到它(session 导向)。本次实现 `link_login`(具名 person-cap)全链;`link_anon` 的匿名物化 = 复用 web_anon_access,后续接线(见 hand-off:anon 落点是 session 粒度的产品决策)。

## DoD reconciliation
| # | DoD | status | proof |
|---|-----|--------|-------|
| M1 | 授权在资源开关(只 owner 能开),链接非授权 | met | share_test:无 enable→`:share_disabled`;非 owner enable 拒 |
| D3 | owner disable 一次撤所有链接,不动已发 cap | met | share_test D3 用例(同链接失效 + c1 cap 存活) |
| M2 | kind 从 URI 推导 + enable 时 conformance | met | mint_cap kind 不变;M2 conformance 用例 |
| 层解耦 | 权限(cap)⊥ 分享(资源开关),飞书式 | met | ShareSetting 不碰 cap 层;cap 撤销走 revoke_cap |
| token | 无状态指针(无 issuer/意图)| met | share_token 7/0(payload 只 target)|
| 闸 | per_tenant/doc/cross_file/Z-1/format | met | per_tenant 事实 ✓ · doc 17/0 · cross_file 1/0 · Z-1 CLEAN · format clean |
| CI | full suite 绿 | pending | push 后 |

**Method friction:** migration 改动(新表)→ rebase 后需 `mix ecto.reset`。

## Merge request
A1 统一重构,PR #1594。取代原 M1 的 issuer-in-token(更干净 + 自带撤销)。A2-1/A2-2/A3/A4-1/config **不受影响**(底座/正交件)。anon 落点(session 粒度)+ link_anon 接线归后续(hand-off 交 Allen)。
