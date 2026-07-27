# A1 — Socialware.Share bearer token + 通用 /socialware/claim(plan + DoD)

分支:`feat/socialware-share-a1-token`(from main `5671a172f`)· Group A 第 1 件 · **纯 infra,零 kanban 文件**

## 目标(additive,不删任何东西)
建"分享一个 URI → 有人点 → 铸指向它的 person cap"主脊的**前两块**:
1. 一个 **bearer 分享令牌**(URI 无关,mint 时不绑人,谁拿到谁能兑)。
2. 一个通用 **`/socialware/claim`** 落点:验令牌 → grantee = 登录点击者 → `mint_cap` 铸 grantee-bound cap。

## 设计决策(已定)
- **sibling,不改 DownloadToken**:DownloadToken 的 person-binding 是硬安全不变量(每个新 token 必须绑 grantee)。bearer 与之相反,混进去会削弱 uploads 安全属性。新建 `Ezagent.Socialware.Share`(core 层 signer,复用 `Phoenix.Token` + `secret_key_base` 模式,同 DownloadToken)。
- **token 载荷** = `%{target: stable_key, behavior: str, actions: [str], issued_at, ttl}`,**无 grantee**(bearer)。TTL 短 + 24h ceiling(照 DownloadToken)。
- **claim 时才绑人**:`/socialware/claim` 在 RequireEntity 后,caller = 登录者 = grantee;`mint_cap(grantee, target, behavior, actions)` 铸 cap(甲 person-cap)。**授权在 mint 侧**(share 时发起人有 access 才签得出 token;token 即凭证)。
- **behavior 反解**:token 里 behavior 是字符串,`Module.concat` 反解(同 kanban 现约定,已签名安全)。

## PR 内步骤(TDD)
1. `Ezagent.Socialware.Share`(core `lib/ezagent/socialware/share.ex`):`mint_link!(target, behavior, actions, opts)` bearer 签 + `verify_link(token)` → `{:ok, %{target, behavior, actions}}`。**先写 test**:round-trip、任意 scheme(entity/session/resource)、篡改/过期拒、无 grantee(bearer)。
2. `EzagentWeb.Socialware.ClaimController`(web):`claim/2` = verify_link → grantee=caller → `mint_cap` → 302 到 caller 自己空间(不焊具体 plugin 页;跳 world 通用入口)。**test**:合法 claim 铸 cap、篡改令牌 403、target scheme 任意。
3. 路由 `get "/socialware/claim"` 挂 RequireEntity scope(同 external feed 邻位)。

## DoD(四性质:枚举契约 · 带证据 · user-facing · closed)
- [ ] `Ezagent.Socialware.Share.mint_link!/verify_link` round-trip 过,支持 entity/session/resource 任意 target scheme,篡改/过期/无效签名拒(单测)。
- [ ] `/socialware/claim?token=` 合法令牌 → 铸出指向 target 的 person cap(grantee=点击者),数据库可见;篡改令牌 403 fail-closed(controller 测)。
- [ ] token bearer:mint 不需 grantee;claim 时任意登录者可兑(= 甲 bearer→mint)。
- [ ] **零 kanban 文件改动**(纯 infra;grep 确认 diff 不含 plugin_kanban)。
- [ ] full suite CI 绿 + 提交后监控。
- [ ] e2e:浏览器点一个 `/socialware/claim` 链接 → 铸 cap → 截图(claim 前无 cap / claim 后有 cap + 落地页)。

## 非目标(留后续 PR)
- caps_toward / grantees_of(A2)· CompositionConsent 泛化(A3)· Mount 重构(A4)· kanban 迁移(Group B)。
- 撤销/申请升级(走 A3/A4)。本 PR 只"分享链接 → 铸 cap"这一跳。
