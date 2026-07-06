# Handoff — kanban-team socialware（#1190）收口与 gap 清单

> **From**: jjkysy · **Date**: 2026-07-07 · **基线**: main `49f0167f`（已 rebase，CI 全绿）
> 系统级问题**不在本文**（在 #1201）；本文只讲 kanban 自己的完成度、待决策 gap、S5 去留。

## 完成度（一句话）

kanban 从 kanban-as-role 迁成可安装的 socialware：**Definition（2 角色槽）+ boot-publish（照 #162）+ 内容协议 relay + BoardView 声明侧（world 通用消费）+ 看板助手 skill（含 gh 协议模块）**，全自包含（world 只删不加、core 只动 test 台账）。

## e2e 验证到哪了（round-2，`docs/e2e/2026-07-06/kanban-full-loop-r2/` 24 件）

**agent 真驱动全链路基本跑通、PTY 零崩溃（短回合策略绕行，bug 本身见 #1201 ①）**：
助手真建卡（先吃 `:unauthorized` 再被授权，CapBAC 未绕）→ dev 真推 GitHub 分支（服务端可见）→ `__done__` 内容规则真命中 relay → 助手 `gh api` 服务端复核 → 推进两档。
**唯一降级**：真 PR 创建被本机 PAT 无 createPullRequest 权限挡（API 403，环境非代码）；补权限后一条腿即补。

## 待你拍板的 kanban gap（都已查验带 file:line）

### G1 — 助手推进 dev 认领的卡：owner 门 vs 协议"assistant advances"
- **现状**：per-node 权限 = admin 或节点 owner（`kanban.ex:29-31` 设计注释；r2 实测助手 `update_node` dev 认领的卡 `:forbidden`）。协议 §c 说"助手复核后推进"——两者有张力，r2 里推进两档实际是"dev 推自己的卡 + 助手推自己建的卡"拼出来的。
- **建议（二选一，我们倾向 a）**：
  (a) setup 流程里 owner 给助手 grant 板的 wildcard cap（§a0 建板后本来就有逐 cap grant 步，机制现成）——协议语义"助手是板管理员"落地；
  (b) 改协议：助手只复核发话，推进由卡 owner 自己做（代码零改，协议文案改）。

### G2 — 看板助手 skill 教了不可达的 CLI 语法（我们修，report only）
- **现状**：kanban 动作按 K5 设计 per-instance 挂载（`application.ex:272` 刻意删了全局 behaviors/0），CLI 全局命令树从 `BehaviorRegistry.list_all()` 派生（`exec.ex:257`）——所以 skill §d 教的 `mix ezagent agent add_node …` 实际派生不出。r2 用同 identity→URI→`Router.dispatch` 的脚本走通（同机制同 CapBAC）。
- **动作**：我们把 skill §d 改成 dispatch 式用法（本 PR 内修正）。**可选平台项**：CLI 要不要长 per-instance 动作面——不阻塞，若你觉得值得我们再提。

### G3 — Definition 物化的 caps 锁不到"晚建的板"（系统级，详见 #1201 ②'）
- kanban 侧现象：materialize 铸的 kanban caps instance 指向助手自身而非板（板是 owner 后建的），owner 需逐个补 grant。机制层 `GrantRecipeCaps/4` 的 `instance_overrides` 已存在（T7g，`grant_recipe_caps_board_scope_test.exs`），断在 Definition 物化路径传不了晚建 URI——**这是平台表达力问题，已作为精确条目递 #1201**，kanban 侧用 §a0 的 owner 补 grant 顶住。

### G4 — R1 链约束把根卡永锁 positioning（小，设计确认）
- r2 实测：R1"stage ≥ 父 ≤ 子"下根节点没法离开首阶段（任何子节点都 ≥ 它）。是有意如此（根=定位卡不动）还是要给根开口？一句话确认即可。

## S5 建议：关闭
S5 原定"join/admission + relay 硬锁"（gated on 你的 Q3）。现在：admission 平台侧 **#1178 已落 main**（owner-approval-to-mount，kanban 无需自做）；relay 硬锁 = #1201 ⑤ from-role condition（已定论待实施，落地后我们一行加固）。**S5 作为独立 stage 已无剩余工作，建议关闭**——除非你想要 kanban 特有的 join 策略（如 dev 槽 cross-owner 加入需助手审批），那是新需求另立。

## 其余小项（record only）
- creds watcher 竞态（config_dir 先于 watcher 出现被跳过）——A②（#1201 ②）落地后整个 watcher 删除，不修。
- 建会话 UI 5s timeout 误报"失败"（后台实际成功）——已在 #1201 已结案区旁注，属 #1202 同族的 UI 反馈问题。
