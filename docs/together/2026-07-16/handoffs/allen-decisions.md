# Handoff: kanban 协作改版 —— 平台决策单（只要决策，不要实施）

> **Date:** 2026-07-16 · **From:** jjkysy（PR #1374 kanban 线）· **To:** Allen（平台架构/权限决策）
> **Tracking:** PR #1374 + docs/notes/2026-07-16-kanban-fix-plan.md（v3 归属重切版）· **Base:** `origin/main` @ 6bfe3d1b3
> **Status:** confirmed —— 诊断已现读代码核实，每项只等一个决策，不含代码

## 0. 来龙去脉（一分钟版，不了解这条线也能接）

kanban 是我们的一块**自包含协作白板 plugin + socialware**：板本身是一个 passive 的 data-host agent（kanban-manager），任何界面操作本质都是一次 dispatch 到这个 agent，成败只看操作者持不持有它的 operate cap（钥匙）；配套的 socialware 再给会话装一个 kanban-assistant（cc-headless"脑"）代人操作。协作模型 2026-07-15 用户定稿：**带认领机制的 excalidraw 式协作**——任何成员加节点即自动认领、认领人编辑自己节点、删除需整子树同主（版主=建板人兜底）、分享链接恒只读、编辑权只来自会话成员身份或版主批准（一句话：设计只剩"钥匙发给谁"）。

我们做了两轮真 UI 测试（两账号手动 + agent-browser e2e），挖出 ㉞ 项问题，按根因归并成 6 组（X1-X6）。实施已按新归属切好：kanban 自包含的全归我（含 kanban 前端）、world 本体前端归 zyli、agent runtime 归 gaga。**剩下 5+1 项卡在系统层面的权限/契约/rule 决策上**——你正在做的 cap-signing/capbac 线（#1438 per-Kind authority v7、#1412/#1409 follow-ups）正是这些问题的根因归属，所以决策单落到你头上。决策不落，实施要么抢跑撞契约、要么绕路造债。每项给：背景（file:line 证据）/ 选项 / 我们倾向 / 卡住谁。

## 1. 背景必读

- `docs/notes/2026-07-15-kanban-collab-model.md` —— 协作模型定稿（9 条规则 + H1-H7 + C1-C4 收敛）。
- `docs/notes/2026-07-15-kanban-layering-debt.md` —— ⑤-㉞ 全部发现（⑤⑥⑦⑧⑨ 已修，修法在文内）。
- `docs/notes/2026-07-16-kanban-fix-plan.md` —— v3 修法计划；本决策单是它的第 7 号 PR，§四是硬编码深扫清单。

## 2. 决策项

### D1 —— join 补发：新 ambient rule 家族追认 + 永久形态归 #1394

- **背景**：「新成员进 session 拿到该 session 已挂资源的钥匙」没有机制。install 点只覆盖 installer（`Installation.grant_installer_view_caps/2`，installation.ex:349-385，rule tag `{:rule, :socialware_install_views, installer}`）；`Mount.reconcile_session_mounts/1` 只重发已记录 grantee（mount.ex:156-183）；`handle_join`（session.ex:781）成功路径零补发 hook。后果：后加入成员看不到 view tab、没有板 operate 钥匙（layering-debt ⑤⑧ TODO）。
- **选项**：
  1. join hook 补发（我们拟实施，domain_session 通用机制、零 kanban 字面）：join 成功路径 (a) member view caps（`view_render_caps` 内核泛化，tag `{:rule, :socialware_member_views, member}`）；(b) mount 表 `access: :operate` 行给新成员发同款钥匙（幂等；`:read` 行不扩散）。
  2. 不做 join hook，直接等 #1394 Entity 双向-caps/mount 永久形态。
- **我们倾向**：选项 1 作过渡 + 永久形态并入 #1394。需要你逐条拍：① 两个 rule 名进 Decision Log（`:socialware_member_views` 新增 + 已在用的 `:socialware_runtime_provision`）；② "编辑 session 成员 = 板全钥匙"授权面（collab C1 直译，但这是 ambient-rule 家族又一员，#154 review surface）；③ `:socialware_runtime_provision` 用了 **transient ctx-cap 不落库**（现有 rule-mint 全持久化，这是首个 transient 用例）——要不要追认为 pattern。
- **卡住谁**：我 PR3（join 补发）——不拍不动工。

### D2 —— ⑥ 普通用户 create_agent 授权：三选项

- **背景**：普通用户全链路**没有任何 `create_agent` 授权点**（workspace `add_member` 只授 `:create_session`；registration 无；`Domain.Agent.materialize_*` #1411 是 trusted-internal 无 CapBAC 门，拿来给用户建板 = 绕过授权）。现行过渡 = D1 的 transient rule（`BoardProvision.create_board` 一次性 scoped create_agent，边界 = 建板人须本 session 成员 + 只造 `passive: true` recipe）。
- **选项**（layering-debt ⑥ 调查原文）：(a) workspace 成员一律授 scoped `create_agent`（照 `create_session`）；(b) 装带 agent-host 的 socialware 时按 definition 声明给 installer 授（= 装即自升权）；(c) 平台 rule 内联 authority 只放行「passive data-host agent」特例（ambient authority）。
- **我们倾向**：(c) 已是事实上的过渡实现，追认或换向都行，但要落 Decision Log。
- **卡住谁**：world UI 建板正路的最终收敛（现已改走 create_board 过渡，不急）；也是 D6 把建板策略搬回 plugin 的前置之一。

### D3 —— ㉜：kanban tab = plugin 级恒显（动 T2-2b view-cap 契约）

- **背景**：用户口径——plugin 与 sw 分离：系统装了 kanban plugin，**所有会话都应显示 kanban tab**；被门控的是板内容/钥匙，不是 tab 显隐（这也让"分享链接在任何会话点开才有意义"）。现状两道门：`BoardView.applies_to?/1`（board_view.ex:51-59，按 installed_definitions 判，kanban 自己的，可改）串 `SessionViewRegistry.applicable_views/2` → `SessionView.authorize_view/3` 查 `{Session, :kanban_render}` cap（session_view_registry.ex:92-102，**T2-2b caller-aware cap gate，平台契约**）。
- **选项**：(a) `applies_to?` 恒 true + 给全体登录成员按 plugin 基线发 `kanban_render` cap（gate 语义不动，发钥匙面变宽）；(b) 允许 view 声明 "ungated/plugin-level" 跳过 authorize_view（改 T2-2b 契约）。
- **我们倾向**：(a)——契约不动，动发钥匙面；与 D1 的 member view caps 是同一供给机制。
- **卡住谁**：我（tab 恒显现归 kanban 前端 = 我们实施）；step1 过渡（join 补发后成员见 tab + 分享点击顺发 render cap）不卡。**红线已知会各实施方**：谁都不许"顺手"把 `applies_to?` 改恒 true。

### D4 —— ⑯ 分享的 workspace 口径：两条路不一致，往哪边统一

- **背景**：chat 转发路 `BoardProvision.forward_board` 有 `same_workspace` 硬守卫（board_provision.ex:267,:292，`:cross_workspace_denied`，#1435）；链接分享路（kanban_share_controller.ex:51-66 → `Mount.mount`）**无 ws 检查**。e2e 实证跨 ws 只读挂载机制通（URI 寻址 + CBAC 无 ws 屏障）。
- **选项**：(a) 都放开（撤 forward 守卫或降为策略）；(b) 都收紧（分享 token 校验收方 ws，fail-closed）。
- **我们倾向**：用户口径（⑯-修正二次澄清）="系统支撑就放开，以系统状态为准"→ (a)。
- **卡住谁**：我 PR4（分享闭环二期）——`receive_shared_board` 的动作签名（要不要带/校验收方 ws）由此决定。

### D5（附带，低优）—— ⑪ dev 发布口径：boot scan 要不要在 dev 开（#1224）

- **背景**：`socialware_manifest_boot_scan: config_env() in [:prod]`（config.exs:33，#1224 刻意设计）；dev 改 manifest 无车道（mix import 另起 VM 撞运行 server 的 _build）。
- **不卡人**：不动口径的修已排（我，独立小 PR：`socialware.import` 走分布式 RPC CLI 在运行节点内执行）。**只问**：dev 也开 boot scan 这个口径变不变（变则 RPC 路降为辅助）。

### D6 —— 债①②分层永久线：mount 折 CompositionBinding + plugin-UI 注册

- **背景**：深扫结论（fix-plan §四）——kanban 字面在 plugin 外的真泄漏全卡两个平台机制：
  - **债①** `BoardProvision` 住 domain_session（#1425 后已瘦成"通用 Mount 的 kanban 消费者"，字面剩默认值+doc，本 PR 顺手上提；但 create/pull/forward 本体 + rule-mint 点搬回 plugin 的前置 = plugin 有合法建-agent 授权路（D2）+ **`Mount` 变成可 dispatch 的动作**）。`Mount` 是运行时挂载（transient 钥匙 + 挂载表），`CompositionBinding`（composition_binding.ex，install 期 role→role cap 的 durable derivation ledger）是同族账本——**mount 要不要折进 CompositionBinding**（一个 durable 的"谁对哪个资源持什么钥匙"账本），是永久形态的核心取舍。
  - **债②** kanban UI/数据/动作物理住 world（kanban_data/kanban_actions/Kanban.tsx + plugin_page_registry 手写条目 + conversation_data `@native_react_ids` 特例）——需要 **plugin-UI 注册机制**（plugin 声明贡献 React 组件 + 数据 reader + 注册表条目），world 只做壳。
- **要你决策的**：永久线的排期与形态（是否并入 #1394 Entity 双向-caps）。本轮任何实施 PR 都不动它；逻辑归属已重切（kanban 面的文件由我方维护），物理搬家等机制。
- **卡住谁**：无（永久线）；但 D2/D6 不落，深扫的 5 组"暂留"永远暂留。

## 3. 时序依赖（哪个决策卡哪个 PR）

| 决策 | 卡住的实施 |
|---|---|
| D1 | 我 PR3（join 补发）——不拍不动工 |
| D2 | world UI 建板正路最终收敛（过渡已在跑，不急）+ D6 前置 |
| D3 | 我（kanban tab 恒显，step2）；step1/过渡不卡 |
| D4 | 我 PR4（分享闭环二期 receive 签名） |
| D5 | 无（RPC 路先行） |
| D6 | 无（永久线，本轮不实施） |

## 4. 红线（我们已经在守的）

- 任何新发 cap 走 `Cap.issue/3` chokepoint（I7 gate），不裸构造 `%Capability{}`。
- 不 `PubSub.broadcast` 到 inbound topic（P14）。
- 不动 `authorize_view` T2-2b 契约、不改 `applies_to?` 恒 true——等 D3。
- retire 板走 `Domain.Agent` 门面（#1411），不直调 terminate。
