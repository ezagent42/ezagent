# dev-together 计划 · 2026-07-09

**planned_at**: 2026-07-09 晨（GMT+9）· lead: allenwoods（**本日缺席**，任务委派 jjkysy 代理，见 §0）
**本周目标**：在 stable 上验证 socialware 全生命周期 + 打通官网全流程（延续）；本日聚焦其中的**自举面**。
**本日头号目标（Allen 定）**：**跑通自举开发流程**（dogfooding dev loop end-to-end）——昨日自举审计 A✔B✔C✗，今天把 C 修通，让「在 ezagent 里开发 ezagent」三面全绿。

## §0 本日两条特殊约定

1. **Allen 本日缺席**：其名下事项（P1-P3 合入定夺、stable 晋级、#1255 命名裁定）**委派 jjkysy 作为代理**执行；coordinator（Claude）承担技术验收与验证的支持位。
2. **昨日转向的收尾**：昨日「验证→加固」转向产出的韧性弧（#1252/#1257/#1259/#1261/#1263）已随 nightly 自动部署——**今晨先在 nightly 上全面复验**（coordinator），复验绿后 jjkysy 决定 stable 晋级（方案 b：晋级 nightly 构建）。

```
今晨 nightly 复验（coordinator：#1252 延迟 vs 5.37s 基线 / #1259 create_session / #1257 冷列表）
   ├─→ 绿 → jjkysy：stable 晋级（nightly 构建含 #1243+#1252+#1257+#1259+#1261+#1263）
   │        └─→ zhaomato：官网 hello session 重建（在部署渠道上 E2E）
   │        └─→ ruihua：在刷新后的 nightly/stable 上探索式测试
   └─→ gaga Track C 修复（独立，立即开工）· P1-P3 验收收尾（独立，今晨）
```

## §1 本日目标与任务

### 头号 — 自举 Track C 修通（gagameow）

昨日审计唯一断的一面：① socialware 编写/安装未起步；② @mention 派发返回 `:unauthorized`（疑 #161 A2 held-cap receive 路径）。两个断点都修通 = 自举三面全绿 = 本日头号目标达成。

### 官网 — hello session 重建（zhaomaota97）

线上 golive hello session 是 #1243 之前旧 Definition 的 stale 实例。步骤（`docs/futures/todo.md` 2026-07-09 节）：归档旧 session → 从新 Definition `ensure_app`/instantiate → 在部署渠道上验证 greeter + curl-llm 回复 E2E。

### skill 分发 P1-P3 — 验收收尾 + 合入定夺（jjkysy 代理 + coordinator）

**当前状态（今晨）**：`[P123-DONE]` 已盖章（~00:40）；coordinator **机械验收已绿**（全局 gate + spec §4 全部 7 个测试文件 29/0，26 文件 diff 含 runbook）。**余下**：coordinator 今晨完成 diff review + 对抗评审 → **jjkysy 以 Allen 代理身份定夺是否合入 main**。合入后 coordinator 跟进 deploy 仓库 Dockerfile 点修的退役。

### stable 晋级（jjkysy，方案 b）

今晨 nightly 复验绿后，把 nightly 构建（含 #1243+#1252+#1257+#1259+#1261+#1263）晋级 stable。

### 安全项 — reuse-join 缺 operator→agent 授权闸（bounded fix）

#1256 评估中发现的 #161 同形漏洞：`membership.ex:751` 丢弃 `_inviter_uri`，非 user 加入者落入 else→`:ok`——reuse-join **没有** operator→agent 授权闸。**bounded fix PR + deny 测试**。owner：coordinator（默认执行位），jjkysy 可改派。

### 5 分钟讨论项（组内过一遍即可）

- **`admin?/1` 设计走向**：coordinator 出 write-up；推荐 = 纯 membership 默认保持，cap-checked workspace-admin bypass 作为后续独立项。
- **viewer 角色基数方向批准**：#1256 Q3——role 增加 per-role 基数声明 `one|many`（Allen 昨晚倾向 yes，今日 ratify）。

## §2 结转项

| # | 结转项 | 来源 | 今日动作 |
|---|---|---|---|
| C1 | socialware 生命周期验证（load/create/delete） | 07-08 头号目标转向 | stable 晋级后可续；不设为今日硬目标（自举 C 优先） |
| C2 | #1245 卸载 UI 浏览器路径绿态演示 | zyli return DoD 部分 | #1259 解阻冷 provision 后，在刷新环境补浏览器绿态截图 |
| C3 | #1255 三个命名裁定 | allowlist sanctioned-pending-review | jjkysy 裁定：AgentPassiveAttributes / RuntimeIdentity / EntityPresenter |
| C4 | 冷启动彩排部署阶段 | 07-08 review 环境形态隔离轴收尾提案 | coordinator 出提案，团队同意则实施 |

## §3 按开发者规划

> 每行 = 一个自含闭环 track。Allen 缺席，其事项并入 jjkysy 行（代理）。coordinator（Claude）为 off-plan support，不占 track 行。

| 开发者 | feishu | 本日 track | 闭环/依赖说明 |
|---|---|---|---|
| gagameow | 黄佳佳 | **头号：Track C 修通**——① socialware 编写/安装失败修复；② @mention 派发 `:unauthorized` 修复（疑 #161 A2 held-cap receive 路径）。**续 #1256 设计**：吸收 Allen Q1 裁定（**PTY 也是无状态执行器**——状态在 recipe 引用的 folder；对话上下文 = PG 回放）+ Q3 基数 `one|many`；**验证 viewer 角色唯一性问题**：`role_name_conflict` 守卫 vs hello 的 fill:human viewer 角色——N 个匿名访客如何共存？官网可能有潜在路由 bug。**Track A 隐患守卫**：产品内 agent 必须拿到显式 worktree，绝不落在 main checkout | 独立，立即开工；Track C 修通 = 本日头号达成 |
| zhaomaota97 | 张宁 | **官网 hello session 重建**：归档旧 golive session（#1243 前旧 Definition 的 stale 实例）→ 从新 Definition `ensure_app`/instantiate → 部署渠道上验证 greeter + curl-llm 回复 E2E（步骤见 `docs/futures/todo.md` 2026-07-09 节） | 依赖部署渠道带 #1243（nightly 已含；stable 晋级后更佳） |
| jjkysy | 姚升悦（Allen 代理） | ① **P1-P3 合入定夺**：coordinator 今晨 diff review + 对抗评审完成后，以 Allen 代理身份决定 integration/skill-distribution 是否合入 main（机械验收已绿）；② **stable 晋级（方案 b）**：晨间 nightly 复验绿后晋级 nightly 构建；③ **#1255 三命名裁定**：AgentPassiveAttributes / RuntimeIdentity / EntityPresenter（allowlist sanctioned-pending-review 条目）；④（填充项）**seed-loader 去重**：hello/kanban Demo 样板 → 共享 SocialwareSeed-backed helper（dealscout 将是第 3 份拷贝，先收口） | ①② 依赖 coordinator 晨间产出；③④ 独立 |
| zyli-developer | 李震宇 | **#1245 卸载 UI 浏览器路径绿态收尾**（C2）：#1259 已解阻冷 provision——在刷新后的环境让 installed-socialware 行出现在成员面板浏览器路径 → 点击卸载 → 截取清空后绿态；截图链入 `docs/e2e/` | 依赖 nightly 刷新（已自动部署）；接自己昨日 return 的 follow-up |
| ruihuachen-designer | 陈瑞华 | **刷新后 nightly/stable 探索式测试**：send 延迟、session 创建、会话列表都是昨日新修的——正适合用户视角复验；发现走 Feishu。**另**：验证 WorldConversationTest 网页 E2E flaky 的可复现性（gaga 报告 latest main 上 flaky）——能复现则带 seed 开 issue | 依赖 nightly 刷新；与脚本化验证互补 |

**Off-plan（support · coordinator/Claude）**：① P1-P3 技术验收收尾（机械验收已绿 → 今晨 diff review + 对抗评审 → 报 jjkysy 定夺）+ 合入后 deploy 仓库 Dockerfile 点修退役；② 晨间 nightly 全面复验（agent-browser：#1252 延迟实测 vs 5.37s 基线、#1259 后 create_session 可用、#1257 冷列表显示 session）；③ `admin?/1` 设计 write-up（5 分钟讨论项）；④ 冷启动彩排部署阶段提案（团队同意则实施）；⑤ 安全项 reuse-join 授权闸 bounded fix（默认执行位）。

> **开工前必读**：`docs/together/contributing/` + 各自任务上下文。返还前 rebase 到 current main + 自测绿（precommit + check_invariants + **相关 scan 含 `uri_query.scan`**）。

## §4 依赖与顺序 / 并行

- **晨间串行段**：coordinator nightly 复验 → jjkysy stable 晋级 → zhaomato 重建 / ruihua 探索（在刷新环境上更稳）。zhaomato 可先在 nightly 上开工，不必等 stable。
- **全程并行**：gaga Track C（头号，独立）· P1-P3 验收收尾（coordinator 今晨）· jjkysy ③④ · zyli C2。
- **安全项**独立，bounded；不阻塞其他线。

## §5 out-of-scope（登记）

- socialware 全生命周期验证（C1）不设为今日硬目标——自举 Track C 优先；stable 晋级后有余力再续。
- git-filter-repo 历史重写：仍需 dev 窗口冻结（延续登记）。

## §6 协作约束

- CI 闸：进 main 的 PR 需 `precommit + check_invariants` 绿 + rebase；**修复类 PR 自测清单显式加 `uri_query.scan`**（昨日事故 E 教训）；判定「绿」以每个 check 的最终结论为准，不以数量为准。
- 评审基准 = `origin/main`；验证面向真实生产流程；UI 验证 agent-browser 截图第一、日志第二。
- 并行 PR 若一方重命名公共符号，另一方合并前 grep 旧符号（昨日事故 D 教训）。

## §7 开工 prompts（每人一段，可直接转发）

### gagameow（黄佳佳）

```
【dev-together 2026-07-09 · gagameow】
背景：昨日自举审计 A✔B✔C✗。本日头号目标 = 跑通自举开发流程，Track C 是唯一断面。
任务：① Track C 修通——socialware 编写/安装失败 + @mention 派发 :unauthorized（疑 #161 A2 held-cap receive 路径），两个断点都修；② 续 #1256 设计——吸收 Allen Q1 裁定（PTY 也是无状态执行器：状态在 recipe 引用的 folder，对话上下文 = PG 回放）+ Q3 角色基数声明 one|many；顺带验证 viewer 角色唯一性：role_name_conflict 守卫 vs hello 的 fill:human viewer 角色——N 个匿名访客如何共存？官网可能有潜在路由 bug，查实即开 issue；③ Track A 隐患守卫——产品内 agent 必须拿到显式 worktree，绝不落在 main checkout。
DoD（可演示）：① 在 ezagent 内完成一次 socialware 编写→发布→安装 + 一次 @mention 派发成功（截图/记录）；② #1256 更新含 Q1/Q3 裁定 + viewer 唯一性结论；③ 默认 cwd 守卫落地（测试或闸）。
汇报：returns/gagameow-trackc-fix.md + Feishu 群。返还前 rebase current main + precommit/check_invariants 绿。
```

### zhaomaota97（张宁）

```
【dev-together 2026-07-09 · zhaomaota97】
背景：线上 golive hello session 是 #1243 之前旧 Definition 的 stale 实例（2026-07-06 建），不含 front-desk relay + curl-llm 委托 + requires:[orchestrator]。
任务：官网 hello session 重建——按 docs/futures/todo.md 2026-07-09 节步骤：① 归档/删除旧网站 session；② 从新 Definition ensure_app/instantiate 重建；③ 在部署渠道上验证 greeter 问候 + curl-llm 回复 E2E。nightly 已含 #1243，可先在 nightly 上做；stable 晋级后在 stable 复验一遍。
DoD（可演示）：部署渠道上一次完整的 hello 会话记录——greeter 问候 + curl-llm 实际回复（截图链）；旧 session 已归档的证据。
汇报：returns/zhaomaota97-hello-session-rebuild.md + Feishu 群。agent-browser 截图为准。
```

### jjkysy（姚升悦 · Allen 代理）

```
【dev-together 2026-07-09 · jjkysy（Allen 代理）】
背景：Allen 本日缺席，其名下三项委派给你。skill 分发 P1-P3 深夜完成：[P123-DONE] 已盖章（~00:40），coordinator 机械验收已绿（全局 gate + spec §4 全部 7 个测试文件 29/0，26 文件 diff 含 runbook）；今晨 coordinator 再做 diff review + 对抗评审。
任务：① P1-P3 合入定夺——coordinator 评审产出后，以 Allen 代理身份决定 integration/skill-distribution 是否合 main；② stable 晋级（方案 b）——coordinator 晨间 nightly 复验绿后，把 nightly 构建（含 #1243+#1252+#1257+#1259+#1261+#1263）晋级 stable；③ #1255 三命名裁定——AgentPassiveAttributes / RuntimeIdentity / EntityPresenter（allowlist sanctioned-pending-review 条目）；④（填充）seed-loader 去重——hello/kanban Demo 样板收敛到共享 SocialwareSeed-backed helper（dealscout 将是第 3 份拷贝）。
DoD（可演示）：① 合入决定 + 执行记录（合则 main 绿，不合则理由）；② stable 晋级完成公告；③ 三条裁定写回 allowlist/issue；④ helper PR 或登记顺延。
汇报：returns/jjkysy-proxy-day.md + Feishu 群。
```

### zyli-developer（李震宇）

```
【dev-together 2026-07-09 · zyli-developer】
背景：#1245 已合，但浏览器路径卸载面板未渲染绿（[data-world-socialware-uninstall-panel]: 0）——当时被本地 py-agent 冷启动超时挡住；#1259 已把冷 provision 改异步，解阻。
任务：在刷新后的环境（nightly 已自动部署）补齐浏览器路径绿态：installed-socialware 行出现在成员面板 → 点击卸载 → 截取清空后状态；截图链沉淀入 docs/e2e/。若面板仍不渲染，定位是前端渲染缺口还是数据面缺口，贴复现开 issue。
DoD（可演示）：浏览器路径完整卸载操作截图链（面板出现 → 点击 → 清空绿态），或一个带复现步骤的 issue。
汇报：returns/zyli-uninstall-ui-browser-green.md + Feishu 群。agent-browser 截图第一。
```

### ruihuachen-designer（陈瑞华）

```
【dev-together 2026-07-09 · ruihua】
背景：昨日修了一串你上次探索正好会撞到的问题：发消息延迟（5.37s→亚秒）、session 创建卡死、重启后会话列表清空。nightly 已带全部修复——正适合用户视角复验。
任务：① 在刷新后的 nightly/stable 上继续探索式测试：重点玩发消息（还慢吗？）、新建 session（还卡吗？）、刷新/重进后会话列表（还空吗？）+ 任何别的玩法；发现走 Feishu 群；② 帮忙试一件事：网页对话页面反复进出/发消息，看会不会偶发不刷新/卡住（WorldConversationTest 在最新 main 上被报 flaky）——能稳定复现就把步骤记下来交 lead 开 issue。
DoD（可演示）：一份非正式发现清单（试了什么/什么好了/什么还坏，截图+大致步骤即可）。无需读代码、无需 rebase。
汇报：Feishu 群（或交 lead 代填 returns/ruihua-playtesting-0709.md）。
```

---

本计划面向全体开发者。团队向 HTML 版见 `plan.html`。
