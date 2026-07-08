# dev-together 回顾 · 2026-07-08 周期

数据窗口：`merged:2026-07-08`（GMT+9 工作日，含 07-08 UTC 深夜的 #1263——按 GMT+9 归本工作日）。本回顾面向全体开发者：呈现产品大局、统计团队效能、诚实复盘事故与教训。

## 指标速览

- **25 个 PR 合入 main**（本工作日范围，见下方口径）
- **另 3 个 PR 合入 `integration/skill-distribution` 分支**（P1-P3，skill 分发实现，深夜完成、`[P123-DONE]` 已盖章，验收进行中）
- **关闭 issue 4 个**：#1226（deploy-seed 决策）· #878 · #879 · #1227（seed 单源收口）
- **一条完整的「生产韧性弧」当日落地**：send 回显解耦 + 逐收件人投递队列 #1252、冷启动持久会话列表 #1257、create_session 冷 provision 解阻 #1259、main-red 热修复 #1261、深夜 main-green 收尾 #1263
- **canary 渠道上线**（canary.ezagent.chat）+ **main 合并 → nightly 自动部署链打通** + **部署能力探针上线**
- **skill 分发线两日成形**：设计文档 #1251（2 轮 codex）→ 实现 SPEC #1254（3 轮 codex）→ P1-P3 三 PR 实现完成
- **贡献者 4 人**：allenwoods · jjkysy · zhaomaota97 · zyli-developer

## 大局

本工作日的主线不是「按计划验证」，而是**一次诚实的转向**：昨日编排线 M1→M3 代码全量入 main 后，本日计划头号目标是「在 stable 上验证 socialware 全生命周期（load/create/delete）」。**但 stable 一接触真实生产环境，就接连暴露出一串「dev 绿、部署碎」的问题**——于是当日从「验证」转向「加固」，产出了一条完整的生产韧性弧，并从这些事故里**共同提炼出一条系统性的隔离轴（environment-shape isolation，见专节）**。这条转向本身，是本周期最有价值的产出。

三条并行推进的线：

- **部署 / 发布链成形**：canary 渠道上线、main 合并自动触发 nightly 部署、部署能力探针（容器内 5 项断言、真实重建上验证）、seed 三态契约下沉到 ConfigStore 原语层（#1242）+ CI reflow 彩排闸、部署级 socialware seed 车道（#1231/#1233/#1246 + kanban #1248 全量迁入）。**「改一次持久化形态就要在旧数据上彩排一次」这条 07-07 教训，本日制度化落地。**
- **生产韧性弧**：send 回显与成员扇出解耦 + 逐收件人投递队列（#1252，测试中 5.37s → <500ms）、冷启动后持久会话列表不再清空（#1257）、create_session 在冷 py provision 下不再卡死（#1259，根因是 Workspace GenServer 内**同步**启 python 子进程，冷 uv ~9.6s 超 5s 预算）、main-red 热修复（#1261）、深夜 main-green 收尾（#1263，listing 去重改 canonical URI struct 键）。
- **能力 / 设计线**：官网 hello 四合一（#1243，curl-agent LLM 委托 + `/hello` 路径路由 + orchestrator→front-desk）、socialware 卸载 UI（#1245）、skill 分发设计 + SPEC + P1-P3 实现、GLOSSARY 四层词约定（#1253）、namespace 点分约定 + 架构闸（#1255）、自举审计（#1247）。

## 环境形态隔离轴（environment-shape isolation）——本周期最重要的一课

本日四起事故看似无关，其实是**同一个盲区的四次显形**：它们全都 **dev 绿 / CI 绿，却在全新容器里碎**——

1. **skill 打包不在发布镜像里**（skill 分发线由此起）；
2. **seed 三态在带 reflow 数据的 DB 上崩 ×2**（旧 seed 数据 + 新镜像）；
3. **uv 冷缓存下 create session 超时**（#1259）。

根因一句话：**我们做到了「状态隔离」（每个租户数据独立），却没做到「环境形态隔离」（fs 布局 / 数据年龄 / 缓存温度）。** dev 与 CI 的环境是「热的、布局熟的、数据新的」；全新容器是「冷的、空的、旧数据或无缓存的」。状态隔离 ≠ 环境形态隔离——**同一份代码在两种环境形态下行为不同**，而我们的闸只覆盖了前者。

本日已落地的反制（counter）：

- **部署能力探针**（容器内断言部署形态，真实重建上验证）；
- **CI reflow 彩排闸**（带上一版本 seed 数据的 DB boot 新镜像，专抓「第三态」bug）；
- **注入延迟的冷启动测试**（把冷 provision 的慢路径显式测出来）。

**明日的系统性收尾（proposed）**：**冷启动彩排部署阶段**——全新镜像 + **空卷**的一次性可弃栈 + 最小冒烟。让「冷/空/旧」这三种环境形态在合入前就被一个闸打到。

## §1 本日工作统计（按主题分组）

### 部署 / 发布链

| PR | 标题 | 开发者 | summary |
|---|---|---|---|
| #1241 | ci: main 合并 → nightly 自动部署 dispatch | allenwoods | main 合并自动触发 nightly（保持 no-pull_request 安全约束） |
| #1242 | feat(config-store): ConfigStore 三态 seed 契约 | allenwoods | absent→write / same→skip / outdated→UPGRADE 下沉到原语层 |
| #1244 | fix(session): 确定性 default-template 名解析 | allenwoods | 模板名解析确定化，去非确定分支 |
| #1231 | feat(socialware): 部署级 seed 机制 + autoservice 迁入 | jjkysy | 部署级 seed 车道机制（栈①） |
| #1233 | feat(socialware): hello 迁部署级 seed 车道 | jjkysy | hello 迁车道（栈②，含 e2e 证据） |
| #1246 | feat(arch): socialware deploy-seed gate | allenwoods | 部署级 seed 架构闸（收编 #1236，栈③） |
| #1248 | feat(kanban): kanban 迁部署级 seed 车道 | jjkysy | kanban 迁车道（同库取代跨-fork #1190） |
| #1229 | chore: 清理部署遗留（旧 runner + 实验文档） | allenwoods | 部署迁移收尾清理 |
| #1249 | chore(socialware): 删 app_sources 死分支 | allenwoods | seed 单源收口（#1227①） |
| #1255 | chore(namespace): Agent.Recipe* 点分约定 + 架构闸 | allenwoods | 命名点分约定，闸 `concatenated_namespace_modules` cap=0 |

### 生产韧性弧

| PR | 标题 | 开发者 | summary |
|---|---|---|---|
| #1252 | fix(session): send 回显与成员扇出解耦 + 逐收件人投递队列 | allenwoods | 5.37s → <500ms（测试）；2 轮 codex，修 HIGH 排序问题 |
| #1257 | fix(session): 冷启动持久会话列表 | allenwoods | 重启后 `/sessions` 不再清空；带租户隔离回归三件套 |
| #1259 | fix(session): 冷 py provision 解阻 create + 接受 2 元 group 形状 | allenwoods | 同步启 python 子进程（冷 uv ~9.6s）改延后异步激活；+ zombie-member 可见性、PendingDelivery 溢出显式化（DLQ） |
| #1261 | fix(kanban): main-red 热修复 — kanban_render → 改名的 RecipeResolver | allenwoods | #1248×#1255 合并顺序碰撞导致 main 短暂红，已恢复 |
| #1263 | fix(session): main-green — listing 去重改 canonical URI struct 键（uri_string_key ×4） | allenwoods | #1257 遗留 4 条 `uri_string_key` scan 违规，full-suite 短暂红；深夜收尾恢复绿 |

### 能力 / 设计线

| PR | 标题 | 开发者 | summary |
|---|---|---|---|
| #1243 | feat(hello): X2b curl-agent 委托 + `/hello` 路径路由 + front-desk | zhaomaota97 | 官网 hello 四合一：curl-agent LLM 委托 + 路径路由 + orchestrator→front-desk |
| #1245 | Add socialware uninstall UI | zyli-developer | socialware 卸载 UI（浏览器路径演示未绿，见 §2） |
| #1251 | docs: skill 分发到已部署 agent — 设计研究 | allenwoods | skill 分发设计（2 轮 codex SOUND） |
| #1254 | docs: skill 分发 P1–P3 实现 SPEC | allenwoods | 实现 SPEC（3 轮 codex） |
| #1253 | docs(glossary): 声明/内容 四层词约定 | allenwoods | GLOSSARY 四层词，消歧概念 |
| #1240 | fix(role-seed): 升级 own-recipe seed 而非误触 boot 冲突 | allenwoods | role_seed_collision 误诊修复 |
| #1235 | fix(socialware): seed built-in upgrade 对 source_turn_id 幂等 | allenwoods | 07-07 事故 B 修复（本日凌晨合入） |
| #1237 | fix(ci): 更新 full-suite runner 标签 — 解阻 CI 队列 | allenwoods | 07-07 事故 A 修复（本日凌晨合入） |

### 文档 / 流程

| PR | 标题 | 开发者 | summary |
|---|---|---|---|
| #1238 | docs(together): 2026-07-07 review + 2026-07-08 plan | allenwoods | 上一周期 close 产物（流程，非产品量） |
| #1250 | docs(todo): 0709 plan 输入 — 官网 session 重建 | allenwoods | 计划输入文档（流程） |

### skill 分发实现（合入 integration 分支，非 main）

| PR | 标题 | summary |
|---|---|---|
| #1258 | P1: release-bundled skill registry | 发布镜像内置 skill 注册表 |
| #1260 | P2: seed skills into EZAGENT_HOME runtime origin | skill 落到运行时源目录 |
| #1262 | P3 skill materialization fold | skill 物化折叠 |

> **口径**：本工作日「今日」范围 = **25 个合入 main 的 PR**（上表除 integration 三条）。其中 #1238/#1250 是**流程 / 文档**（上一周期 close 产物 + 计划输入），不计入产品量。#1235/#1237 是 07-07 两起事故的修复，本日凌晨合入、#1263 是深夜 main-green 收尾——均按 GMT+9 归本工作日。P1-P3（#1258/#1260/#1262）合入 `integration/skill-distribution`，**未进 main**，单独计。

## §2 事故与教训（诚实复盘——这些最有价值）

### 事故 A — 头号计划目标滑动：socialware 生命周期验证未完成（转向加固）

- **经过**：本日 plan 头号目标是「stable 上验证 socialware load/create/delete」。stable 一接触生产就暴露 send 延迟（5.37s）、冷启动会话列表清空、create session 冷 provision 卡死等一串问题——**验证无法在这样的地基上进行**，当日理性转向加固（#1252/#1257/#1259/#1261）。生命周期验证**结转 07-09**。
- **教训**：这不是失败，是**正确的转向**——但要显式记账：「25 PR 合入」不等于「计划目标达成」。头号目标滑动，本 review 明写，不用合并数掩盖。转向的产出（韧性弧 + 环境形态隔离轴）价值高于原计划的验证本身。

### 事故 B — seed 三态在 reflow 数据上崩（×2）

- **经过**：seed 升级路径在「带旧版本 seed 数据的 DB」上非幂等/误诊（role_seed_collision 误当 boot 冲突）。全新 DB CI 绿，只有 reflow 场景暴露。
- **修复**：#1235（source_turn_id 幂等）+ #1240（升级 own-recipe seed 而非误触冲突）+ #1242（三态契约下沉原语层，从根上统一 upgrade 语义）+ CI reflow 彩排闸。
- **教训**：**改变持久化形态需要在旧数据上彩排**——见环境形态隔离专节。本日已把它从「教训」变成「闸」。

### 事故 C — create session 冷 py provision 超时

- **经过**：create_session 在 Workspace GenServer 内**同步**启 python 子进程，冷 uv 冷缓存约 9.6s，超 5s 预算 → 卡死。
- **修复**：#1259 改为延后异步激活；顺带把 PendingDelivery 溢出显式化（接 DLQ）、zombie-member 可见、统一 `{:ok,[uri]}` 返回形状。
- **教训**：**缓存温度是一种环境形态**——热缓存的 dev 测不出冷缓存的超时。注入延迟的冷测试已补。

### 事故 D — #1248×#1255 合并顺序碰撞导致 main 短暂红

- **经过**：#1255 把 `Agent.RecipeResolver` 改名，#1248（kanban）与之并行；合并顺序下 `kanban_render` 仍引用旧名，main 短暂红。
- **修复**：#1261 热修复恢复。
- **教训**：**并行 PR 若一方重命名公共符号，另一方合并前须 grep 旧符号**——与团队既有「重命名前 grep 全部旧符号」原则一致；本次是并行合并顺序放大了它。

### 事故 E — 两次过早合并：#1257 遗留 scan 违规致 full-suite 深夜短暂红

- **经过**：#1257 合入后遗留 4 条 `uri_string_key` scan 违规（listing 去重用了字符串 URI 键），main 的 full-suite 深夜短暂红。当晚共**两次过早合并**——判定「绿」时看的是数量/局部输出，而不是**每个 check 的最终结论**。
- **修复**：#1263 深夜合入——listing 去重改用 canonical URI struct 键，main 恢复绿。
- **教训**：① **验证要看每个 check 的结论（CONCLUSION），不是数数**——"N 项通过"不等于"全部结论为 pass"；② **修复类 PR 的自测清单必须包含 `uri_query.scan`**（URI 相关改动尤其如此）。这与既有「gate on EXIT=0 AND 结论 grep」原则同源，本次是它在 scan 维度的显形。

### 事故 F — 自举 Track C 失败 + 卸载 UI 浏览器路径未绿

- **Track C（gagameow #1247）**：socialware 编写/安装未起步，@mention 派发返回 `:unauthorized`——自举三面里唯一断的一面，**明日头号**。Track A（改码提 PR）、Track B（plugin 骨架）均通。
- **卸载 UI（zyli #1245）**：PR 已合，但**浏览器路径的卸载面板始终未渲染绿**（`[data-world-socialware-uninstall-panel]: 0`）——被本地 py-agent 冷启动超时挡住（与事故 C 同类冷 provision 问题）。**「已合」≠「已验证」**：后端 + 成员面板截图有，浏览器点击卸载的绿态截图缺，follow-up 结转 07-09。

## §3 数据统计

### close 对账（required accounting）

| 问题 | 答案 |
|---|---|
| plan.md 里有几条 track？ | 6 条（allenwoods lead 线 · zhaomaota97 · gagameow · jjkysy · zyli · ruihua） |
| 到了几份 return，几份迟到？ | 5 份，0 迟到（均标 on_time） |
| 几份进了 stack？ | 5 份全部对账入 `stack.md`（无遗漏） |
| 几个合入 main？ | 25 个 PR（其中 5 份 return 映射 #1231/#1233/#1246/#1248/#1245） |
| superseded / out-of-scope / blocked / deferred？ | superseded：#1190→#1248、#1236→#1246；deferred：git-filter-repo（需冻结窗口，plan §5 登记） |
| 相关 GitHub PR 状态？ | 合 main 25；合 integration 分支 3（#1258/#1260/#1262，`[P123-DONE]` 已盖章、机械验收绿，diff review + 对抗评审后由 jjkysy 定夺进 main）；有意保持 open 2（#1247 审计草稿、#1256 设计草稿） |

> **流程债显式登记**：allenwoods lead 线（25 PR 中绝大多数）、zhaomaota97 #1243、gagameow 草稿件、ruihua 探索——**均无 return 文件**，当日 context 高度集中、直接走 PR。记为流程债（见 §method-deltas）。plan §3 有 6 条 track，但只有 2 人（jjkysy/zyli）走了 return 流程——这是本周期最大的**流程覆盖缺口**。

### 按开发者（口径：能力交付，非 PR 数排名）

| 开发者 | feishu | 本日交付 | summary |
|---|---|---|---|
| allenwoods | 林懿伦（lead） | 韧性弧 5（#1252/#1257/#1259/#1261/#1263）+ 部署/发布链 + skill 分发设计/SPEC/P1-P3 + GLOSSARY/namespace 闸 | 独力扛下转向后的加固全量 + 三条设计线；context 高度集中 |
| jjkysy | 姚升悦 | #1231/#1233/#1246 栈 + #1248 kanban | 部署级 seed 车道全量迁入，走了完整 return 流程（唯一） |
| zhaomaota97 | 张宁 | #1243 官网 hello 四合一 | curl-agent LLM 委托 + 路径路由 + front-desk；官网能力面 |
| zyli-developer | 李震宇 | #1245 socialware 卸载 UI | UI 交付；浏览器路径验证受冷 provision 阻（DoD 部分） |
| gagameow | 黄佳佳 | #1247 自举审计（A✔B✔C✗）+ #1256 设计草稿 | 审计交付诚实（跑通贴证据、断点贴复现）；Track C = 明日头号 |
| ruihuachen-designer | 陈瑞华 | 探索式测试（无 PR，计划内） | 用户视角发现走 Feishu |

### 效能观察

- **转向比硬扛计划更值**：头号目标（生命周期验证）在暴露的地基问题面前理性让位于加固——韧性弧 + 环境形态隔离轴的产出，价值高于按原计划勉强验证。**识别「地基不稳时先修地基」是成熟信号。**
- **流程覆盖缺口**：6 条 track 只有 2 人走 return。lead 线 context 集中虽合理，但「直接走 PR 不填 return」让 close 对账要从 PR 反推——下一步须把 return 流程覆盖到 lead 线（见 method-deltas）。
- **codex 先行的持续回报**：skill 分发走「设计 #1251（2 轮）→ SPEC #1254（3 轮）→ P1-P3 实现」，实现阶段顺滑。

## §4 profile 更新（据本日 review）

- **allenwoods**：强化「架构/地基/大改造 + 生产加固 + 部署链」标签；本日独力扛转向后加固全量 + 三条设计线。**注意点**：context 高度集中在一人是深度改造的合理副产品，但流程上须补 return 覆盖，避免 close 靠 PR 反推。
- **jjkysy**：部署级 seed 车道全量迁入（机制 + hello + kanban），**唯一走完整 return 流程的人**——流程纪律标签强化。适合地基 + 迁移 + 流程示范。
- **zhaomaota97**：官网 hello 四合一（curl-agent 委托 + 路径路由 + front-desk）——前端/官网能力面深化。
- **zyli-developer**：socialware 卸载 UI；**新增注意点**：浏览器路径 E2E 受本地 py-agent 冷启动阻，UI「已合」需补浏览器绿态演示才算 DoD 全满——与冷 provision 同类环境形态问题。
- **gagameow**：自举审计诚实（三面 works/breaks/gaps 齐，Track C 断点贴复现）+ agent×flavor 设计草稿——运维 + 产品 sense + 结构性归因能力。

## §method-deltas（MANDATORY — 促进，不只收集）

本周期的流程 gap 与处置：

1. **lead 线无 return 文件 → close 靠 PR 反推**（流程债，owner: lead）。
   - **映射规则**：现有规则「Timestamp every return / Reconcile the whole ledger」要求每条 track 都有 return；本日 6 条只有 2 条有。
   - **处置**：跟踪项——lead 自己的 track 也须走 return（哪怕事后补一份薄 return 指向已合 PR），否则 close 对账不可机检。列为 process-debt，不改 skill 契约（契约已够，是执行覆盖问题）。
2. **头号目标滑动未在当日显式记账 → 靠 review 事后点明**（流程改进）。
   - **映射规则**：review.md「any DoD that slipped」要求显式记滑动；本次做到了，但**是在 close 才记，非当日 plan 转向时记**。
   - **处置**：建议 mid-day pivot 时 lead 即在 plan 追一行「转向说明」，不等 close。列为 process-debt。
3. **两次过早合并 → 验证结论化**（流程规则，owner: 全员）。
   - **映射规则**：既有「gate on EXIT=0 AND 结论 grep」原则；本次在 scan 维度失守（事故 E）。
   - **处置**：修复类 PR 自测清单显式加 `uri_query.scan`；判定「绿」以**每个 check 的最终结论**为准，不以数量/局部输出为准。列为流程规则更新。
4. **环境形态隔离轴 → 已从教训升级为闸**（method 升级，已落地）。
   - 部署探针 + CI reflow 闸 + 冷测试三个 counter 本日落地；**冷启动彩排部署阶段**是提议中的系统性收尾（07-09 platform 项）。这是本周期 method 的正向增量，非债。

---

本回顾面向全体开发者，仅含团队相关内容。团队向 HTML 版见 `review.html`。
