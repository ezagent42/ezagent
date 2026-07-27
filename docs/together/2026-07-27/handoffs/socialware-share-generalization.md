# Handoff：URI 授权分享统一机制（infra PR → Allen 拍板）

- **类型**：平台 infra 设计（动 domain_session 授权底座,不是 kanban 业务;单独 PR)
- **来源**：kanban 示范重构(PR #1474)三轮讨论 + 两次代码查实的收敛
- **触发**：Sy —— "既然 kanban 数据是一个 agent,为什么和别的 agent 分享、或者所有有 URI 的分享不能走一致的?"

---

## 一句话

**分享 = 授予某人一个指向某 URI 的 cap。** 这天然 URI 无关(`mint_cap(grantee, target_uri, behavior, actions)` 里 target 是任意 URI)。所以分享不该 kanban 专属、甚至不该"数据宿主专属",而该是一个**对任意 URI 授 cap 的统一编排**。kanban 现在自己包了一层(Phoenix.Token + 专属 controller + 规则 8 气泡)——那层本该是通用底座。请 Allen 拍这个统一机制 + 一个前置的模型裁决。

---

## 核心原则:授权层统一(URI 无关),使用层按 kind

| 层 | URI 无关? | 谁负责 |
|---|---|---|
| **授权层**:签令牌 → 铸 cap → 审批升级 → 从 cap 派生可见 | ✅ 统一底座 | infra |
| **使用层**:拿到 cap 后怎么 render/用那个 URI | ❌ kind 相关 | plugin 声明 |

kanban 的病:把**授权层**也做成了 kanban 专属。渲染是 plugin 的,授权不是。

---

## 一个必须先裁决的分叉:系统里已并存两套分享模型

- **socialware feed 模型**：链接 → 匿名入会 → membership **live 授权**(令牌不是授权、成员资格实时复查,`ChatFeedAuth`/`AnonIngress`)。这是 **session 这个 kind 的"参与"语义**,不是通用分享。
- **person-cap 模型**：链接 → 铸 person cap(令牌即凭证、兑换即铸,kanban `share_receive`)。这**就是"对 URI 授权"本身**。

**请 Allen 裁决:通用 URI 分享统一走 person-cap 模型**(feed 那套留给 session 的参与语义)。否则通用 claim 落点要同时伺候两套哲学 = 缝合怪。Sy 已在 kanban 侧选定 person-cap(不造展示会话)。

---

## 统一机制 = 5 块积木(xy 判定,file:line 实证)

```
[② bearer 令牌(带 target_uri)] → [⑤ 通用 claim 落点] → [① mint_cap 铸 person cap(任意 target)]
          ↓                                                      ↓
[③ caps_toward:从 cap 派生"我能看到哪些 URI 资源"]      [④ Consent:申请→owner 批准→升级(任意 target)]
```

| 积木 | X/Y | 现状实证 | infra 要做什么 |
|---|---|---|---|
| **① 铸 cap** | **Y** | `CompositionCaps.mint_cap/4`(composition_caps.ex:126-179)通用、参数化、fail-closed;kanban 已正确复用 | 不动 |
| **② 令牌服务** | **X** | 6 处各签 `Phoenix.Token`(kanban 还 plugin/controller 两文件手工对齐 salt,world_share_actions.ex:28-30 ↔ kanban_share_controller.ex:21-23) | 以 `Ezagent.Uploads.DownloadToken`(core,已有 TTL 双层封顶 + person-binding,download_token.ex:69/113-119)为底,**补一个"bearer 不记名可兑换"轴**(它现在结构性禁止无 grantee mint,:31-33) |
| **③ cap 派生可见性** | **X** | `union_cap_boards` kanban 私有、硬编码 `behavior: Kanban`(world_data.ex:165-181);workspace/session/kanban 三处各写 `EntityCaps.load`+手工过滤(listing.ex/workspace_reads.ex:191/session_reads.ex:508) | 补通用 `caps_toward(holder, behavior)` / "从 caller_caps 派生指向某 behavior 的可见实例";`EntityCaps` 现只有整包 `load/1`,`CapabilityRegistry` 只有 `data_owner_of` 正向、无反向 holders 索引 |
| **④ 审批升级** | **Y-半** | **`CompositionConsent` 原语 URI 无关**(schema binding_id 任意 string + target/source_owner + approval 状态机 + `pending_for_owner/1` owner 待办箱,composition_consent.ex:23-67);**但入口绑死 composition**:`sync(%CompositionBinding{})`(:79)、`command(binding_id, session_uri, ...)`(:124,查 session_mismatch)、binding_id 由 `CompositionBinding.id_for(subject)` 从 session/role/cap_identity 构造;调用方全是 composition_caps。kanban 规则 8(world_share_actions.ex:187-244)重复造了这个轮子 | **泛化创建/命令入口**,让它接受"任意 `(grantee, target_uri, actions)`"、脱离 CompositionBinding + session_uri。原语层(状态机+待办箱)不用重写 |
| **⑤ claim 落点 + 模型归一** | **X** | kanban_share_controller 孤立落点(verify→plugin claim→302);feed 侧通用形状 `AnonIngress` 绑死 session-membership 模型 | 补 plugin 可注册 claim handler 的通用 `/socialware/claim`(person-cap 语义);+ 上面的模型裁决 |

**结论**:5 块里 **①④ 的原语是现成的(不重造)**,**②③⑤ + ④的入口是真缺口**,全是"URI 无关授权底座"级改动。

---

## 待 Allen 决策

1. **模型裁决**:通用 URI 分享统一走 **person-cap 模型**?(feed 留 session 参与语义)
2. **infra PR 范围**:②令牌 bearer 轴 + ③caps_toward + ④Consent 入口泛化 + ⑤通用 claim 落点,是一个 PR 还是拆几个?
3. **归属轨**:跟 Allen 此前的 read-plane / share 后端统一车道是不是同一件事?

## 对本 PR #1474 的影响(已按此收敛)

- kanban 分享**铸 cap 那半已站在正确底座 `mint_cap` 上(Y,没造 cap 轮子)**;唯一自造轮子是规则 8 审批,收编它要泛化 infra → **不在本 PR**。
- 本 PR 关于分享**不做大改**:保留 person-cap 现状 + 清理 web 独立页 redirect 硬编码(`/plugins/kanban` → world,world 也是 plugin 不该焊)。
- 分享统一收编**整体移交本 handoff 的 infra PR**。符合"业务修正+清理在本 PR,动底座单独 PR"的划分。
