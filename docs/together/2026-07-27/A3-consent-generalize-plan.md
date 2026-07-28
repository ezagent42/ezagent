# A3 — URI-share owner-consent(plan + DoD)

> **实现转向(xy 查证后)**:原计划"加进 CompositionConsent 同表"撞到硬约束——`consent.binding_id` 是 NOT-NULL 外键指向 `composition_bindings`(级联删),是**刻意的语义生命周期耦合**(consent = 一条 composition 边的两方审批态)。且 composition 是**两方**(target ISSUE + source STORE)、URI-share 是**一方**,语义不同。故改为 **sibling**:独立 `share_consents` 表 + `Ezagent.Socialware.ShareConsent` 模块,复用状态机**形状**,不碰 composition 表。下文"加在 CompositionConsent"段以此为准修正。

---


分支:`feat/socialware-share-a3-consent`(from main `834488c82`)· Group A · **纯 domain_session,零业务/kanban 文件**

## 目标(additive,不碰 composition 现有路)
给 `CompositionConsent` 加一个 **URI 无关的入口**:任意 `(target_uri, grantee)` 的"申请→资源主人批准/拒绝"审批,复用现成状态机 + owner 待办箱 + 幂等 command log。让 kanban rule-8 手搓审批(Group B 迁)、和未来任意 URI 分享升级共用一套。

## xy 调研(已定)
- **状态机 + 待办箱 URI 无关、可复用**:`approved?/3`、`pending_for_owner/1`、`get_by_binding/1`、`transition/2`、`owner_match/3`、schema(`socialware_composition_consents`)。
- **耦合只在写入口**:`sync(%CompositionBinding{})` 要 binding 结构;`command(binding_id, session_uri, …)` 的 `apply_command` 去 `Repo.get(CompositionBinding)` + 验 `session_uri` + `authenticate_owner` 从 binding 读 owner。
- **generic decide 从 consent 行自己的 `target_owner_uri` 认证**(行里已存 owner),**不需 CompositionBinding**。
- URI-share 只用 **target 侧**(资源主人单方批准),不用 composition 的 source/两方 consent。

## 新增(加在 CompositionConsent,同 schema)
1. `request(target_uri, grantee, opts)` —— binding_id = `"share:"<>stable_key(target)<>":"<>stable_key(grantee)`;`target_owner_uri` = `data_owner_of(target)`(解析存行);`target_approval=:pending`。幂等(同 binding_id 已存 → 返回现有)。owner 解析不出 → fail-closed。
2. `decide(binding_id, :approve|:deny, actor, idempotency_key)` —— 取 consent 行(FOR UPDATE)→ 验 `actor == 行 target_owner_uri`(owner_match)→ `transition` → 更新 → 写 `CompositionConsentCommand` 幂等 + replay 保护。**不碰 CompositionBinding/session_uri**。
3. 读复用 `approved?(consent, :target, owner)` / `pending_for_owner`。

## TDD
- test:request 建 pending + owner=data_owner;decide(:approve) by owner → approved? true;decide(:deny) → false;非 owner decide → :consent_actor_not_target_owner 拒;重复 idempotency_key → replay 幂等;request 幂等。
- impl:request/3 + decide/4(复用 transition/changeset/owner_match/CompositionConsentCommand)。

## DoD(四性质)
- [ ] request→approve→approved? true;deny→false。
- [ ] 非 owner 拒;幂等(request 去重 + decide replay)。
- [ ] 不碰 composition 现有 sync/command(grep 确认)。
- [ ] 零 kanban/业务;push 前本地 format-check + oversized + doc_coverage。
- [ ] full suite CI 绿 + Loop C。

## 非目标
kanban rule-8 迁本入口(Group B)。source 侧/两方 consent(composition 不动)。
