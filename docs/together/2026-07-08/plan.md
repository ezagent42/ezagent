# dev-together 计划 · 2026-07-08

**lead_confirmed**: true（2026-07-08，GMT+9）
**本周目标**：编排线（orchestration-as-socialware）落成后，**在新部署的 stable（app.ezagent.chat）上验证 socialware 全生命周期**，并打通**官网全流程**（全体成员可回复网站操作）。
**方向**：昨日 M1→M2→M3 代码全量合入 → 本日转向**在稳定环境上验证能力可用**（load/create/delete + requires 自动装齐 + 官网成员响应）。

## §0 关键依赖链（primary 目标是被 gate 的——先打通再验证）

primary 目标不是「立即可执行的并行项」，而是一条**串行依赖链**：

```
#1235 已合入 ✓（2026-07-08 02:27 UTC，seed upgrade 对 source_turn_id 冲突幂等）
   └─→ stable 带 #1235 重新部署，boot 绿（health 通过）  ← 当前链首（在途）
          └─→ socialware load / create / delete 验证
          └─→ M3 requires 冒烟（装依赖编排器的 socialware → 编排器自动装齐）
          └─→ M2 default-template 编排器安装验证
          └─→ 官网全流程（全体成员可回复网站操作）
```

**#1235 已合入（修复 land），但 stable 尚未带该修复重新部署跑通**（见 07-07 review 事故 B）。**当前链首 = stable 重新部署 boot 绿**；链首未通前，下游验证无法开始——本 plan 把它写成显式链条，避免误读为可立即执行。

## §1 本日目标与缺口

### 主目标 — stable 上 socialware load / create / delete 验证

**前置**：#1235 已合入 ✓ → stable 带 #1235 重新部署 boot 绿（当前链首，在途）。
**验证步骤**（agent-browser，面向真实生产流程）：
1. agent-browser 以 admin 登录 app.ezagent.chat；
2. 在一个 session 中**列出**已安装 socialware；
3. **安装**一个 socialware（hello，或经 manifest import）；
4. 验证**物化**：成员出现、views 挂载；
5. **卸载/移除**，验证**干净移除**：无残留 rule（T4 #1221 修复的正是这条）；
6. **M3 requires 冒烟**：安装一个 requires 编排器的 socialware → 验证编排器**自动装齐**。

### 次目标 — 官网（official website）全流程

运行网站 socialware，验证**全体团队成员都能回复网站操作**（A② host-login 继承修复 + credential cascade 应让成员 agent 正常响应）。

### 结构项 — seed 框架三态契约 + CI reflow 闸（lead 批准新增，assignee: allenwoods）

**背景证据**：今晚三次部署失败（#1235 source_turn_id 重试冲突、role_seed_collision 误诊、definition upgrade）**全部通过了 fresh-DB CI，却在带旧版本 seed 数据的 nightly reflow 上崩溃**——同一个结构缺口的三次显形，做一次结构性修复而非继续逐点补：

1. **seed 三态契约下沉**：把三态契约（**absent→write / same→skip / outdated→UPGRADE**）下沉到 ConfigStore 的 seed 原语层，让每个 built-in seed 调用方（DefinitionRegistry、RecipeRegistry、未来新增）**统一获得 upgrade 语义**，而不是各自手搓幂等。
2. **CI reflow 彩排闸**：新增 CI 闸——用**带上一版本 seed 数据的 DB**（而非仅 fresh-DB）boot 新镜像，专抓「第三态」（outdated→UPGRADE）类 bug。

这是 07-07 review 事故 B 教训（「persistence-shape 变更需要 reflow 彩排」）的制度化落地。

### 延后项 — git-filter-repo 历史重写

对 tunnel UUID / CF account id / KV namespace id / Tailscale IP / test key 的历史重写——**仅在 dev 窗口冻结时执行**（按迁移计划）。本日不做，除非明确进入冻结窗口。

## §2 结转项（carry-over，stable 打通后验证）

| # | 结转项 | 来源 | 验证点 |
|---|---|---|---|
| C1 | T2 spec ⑦ M2-follow-up 一致性 warn | #1225 已合 | 在 stable 上确认 conformance warn 行为 |
| C2 | deploy-seed 车道 | jjkysy 的 PR，pending CI re-run | CI 重跑后合入 |
| C3 | M2 default-template 编排器安装 | #1223 已合 | stable 上默认模板自动装编排器 |

## §3 按开发者规划

> 每行 = 一个自含闭环 track；stable 依赖链由 lead 内部串行推进（合 #1235 → 部署 → 验证），下游验证在 stable 绿后分派。

| 开发者 | feishu | 本日 track | 闭环/依赖说明 |
|---|---|---|---|
| allenwoods | 林懿伦（lead） | #1235 已合 ✓ → stable 带修复重新部署 → 主目标 socialware load/create/delete + M3 requires 冒烟 + M2 default-template 验证；**结构项：seed 三态契约下沉 + CI reflow 闸**（见 §1）；**nightly 自动触发 + 内测 playground 指定**：① main 合并 → nightly 自动部署（现仅 19:00 UTC 定时/手动 dispatch；如 ezagent CI main push → repository_dispatch → ezagent-deploy，保持 no-pull_request 安全约束）② 定内测 playground 渠道（nightly 最新但不稳 vs beta 晋级版；给出推荐并配置） | 依赖链持有者，context 在本人（原则①闭环）；stable 绿后可分派下游；结构项/nightly 项独立于 stable 链，可穿插推进 |
| zhaomaota97 | 张宁 | **官网全流程**：运行网站 socialware，验证全体成员可回复网站操作。**子项：hello 页面路径可达性测试**——验证 hello 页面在 `app.ezagent.chat/hello/xxx` 路径下的对外可达性（Cloudflare 固定 hostname + 路径路由，非通配子域——域名走 Cloudflare tunnel 固定 hostname ingress，通配子域不可行）。（follow-up：**hello 纯 manifest 重表达**——hello 开发归属本人，官网全流程后跟进） | 前端/官网底座持有者；依赖 stable 绿 + credential cascade |
| gagameow | 黄佳佳 | **ezagent-in-ezagent 自举能力审计（dogfooding）**：验证「在 ezagent 里开发 ezagent」今天是否可行，三个面逐一验证：① **改代码库 + 提 PR**——ezagent session 内的 agent 修改 esr-ng 仓库并提交 PR；② **产出 plugin**——从内部开发一个新 ezagent 插件；③ **生成 socialware**——从内部编写 + 发布 + 安装一个新 socialware。**交付物 = 验证报告**：每个面「今天能跑通什么 / 哪里断 / 缺口在哪」 | 自含闭环（审计 + 报告同一人）；不依赖 stable 链，可立即开工 |
| jjkysy | 姚升悦 | deploy-seed 车道 PR CI re-run → 合入（C2）；socialware boot 时序面支持 | 自含闭环；CI 重跑后 lead 合入 |
| zyli-developer | 李震宇 | 协助主目标 E2E：agent-browser socialware 安装/卸载场景脚本化 + UI 呈现校验 | 依赖 stable 绿；E2E 强项 |
| ruihuachen-designer | 陈瑞华 | **探索式玩法测试（play-testing）**：在新部署的 stable 上以真实用户视角自由探索平台各项玩法——session、agent、socialware 体验（hello / kanban / dealscout / autoservice）、按角色名 @mention（T3 新功能）、magic-link 登录流、world UI。**非脚本化 E2E**——像真实用户一样玩，报告任何困惑、损坏或惊喜之处。**交付物 = 非正式发现清单**：试了什么 / 什么出乎意料 / 什么坏了 | 依赖 stable 绿；用户视角/产品 sense 强项，与脚本化 E2E（zyli）互补 |

> **开工前必读**：`docs/together/contributing/` + 各自 handoff。先讨论确认范围再开工；返还前 rebase 到 current main + 自测绿（precommit + check_invariants）+ 附 contributing_read_through。

## §4 依赖与顺序 / 并行

- **强串行链首**：#1235 已合 ✓ → stable 带修复重新部署绿（当前链首）。链首未通，主目标与官网全流程都不能开始（见 §0）。lead 内部串行推进链首。
- **链尾并行**：stable 绿后，socialware 验证（allen/zyli）、官网全流程（zhaomaota97）与探索式玩法测试（ruihua）可并行——共享 stable 环境但操作面不同。
- **deploy-seed 车道（C2）**独立于 stable 链，可提前推进 CI re-run。
- **结构项（seed 三态契约 + reflow 闸）**独立于 stable 链，allenwoods 可在链首等待窗口穿插推进；reflow 闸落地后反过来保护后续所有部署。
- **自举审计（gagameow）**独立于 stable 链（在现有环境验证三个面），可立即开工、全程并行。

## §5 out-of-scope（登记）

- **git-filter-repo 历史重写**：迁移计划内、需 dev 窗口冻结——本日不执行（延后项，非偏离）。
- backlog（未排）：待 stable 验证暴露的问题按需开 issue。

## §6 协作约束

- CI 闸：进 main 的 PR 需 `precommit + check_invariants` 绿 + rebase；返还前自测绿。
- 评审基准 = `origin/main`（禁读陈旧工作树）。
- 验证面向真实生产流程（app.ezagent.chat），非改测试 harness。
- UI 验证优先 agent-browser 截图，再看日志。

## §7 开工 prompts（每人一段，可直接转发）

> lead 可将下列 prompt 逐段复制转发给对应人/agent 开工。每段自含：背景、任务、可演示 DoD、汇报处。依赖 stable 绿的任务，转发时机 = lead 宣布 stable 部署绿之后。

### allenwoods（林懿伦 · lead）

```
【dev-together 2026-07-08 · allenwoods】
背景：今晚三次部署失败（#1235 source_turn_id 重试、role_seed_collision 误诊、definition upgrade）全部 fresh-DB CI 绿、reflow 崩——同一结构缺口；另 nightly 目前仅 19:00 UTC 定时/手动 dispatch，无 main 合并自动触发。
任务：① seed 三态契约下沉——把 absent→write / same→skip / outdated→UPGRADE 下沉到 ConfigStore seed 原语层，DefinitionRegistry / RecipeRegistry / 未来调用方统一获得 upgrade 语义，不再各自手搓幂等；② CI reflow 彩排闸——CI 增加「带上一版本 seed 数据的 DB boot 新镜像」场景，专抓第三态 bug；③ nightly 自动触发（main 合并 → repository_dispatch → ezagent-deploy，保持 no-pull_request 安全约束）+ 指定内测 playground 渠道（nightly vs beta，给出推荐并配置）。
DoD（可演示）：① 一个会在「旧 seed 数据 + 新镜像」下失败、修复后转绿的 CI 用例（invariant test）；② 三个既有 seed 调用方全部改走原语层（grep 无残留手搓幂等）；③ 演示一次 main 合并自动触发 nightly 部署 + playground 渠道公告。
汇报：returns/allenwoods-seed-contract-nightly.md + Feishu 群。返还前 rebase 到 current main + precommit/check_invariants 绿。
```

### zhaomaota97（张宁）

```
【dev-together 2026-07-08 · zhaomaota97】
背景：stable（app.ezagent.chat）带 #1235 重新部署后（等 lead 宣布绿），官网 socialware 要走全流程；hello 页面对外可达性走路径路由（Cloudflare tunnel 固定 hostname，通配子域不可行）。
任务：① 官网全流程——运行网站 socialware，验证全体团队成员都能回复网站操作（A② host-login 继承 + credential cascade 生效）；② hello 页面路径可达性——验证 hello 页面在 app.ezagent.chat/hello/xxx 路径下对外可达（固定 hostname + 路径路由）；③ follow-up（本日排不下则顺延登记）：hello 纯 manifest 重表达。
DoD（可演示）：① 每位成员至少一条对网站操作的回复（截图/记录逐人列出）；② 未登录浏览器直接打开 app.ezagent.chat/hello/xxx 页面截图；③ follow-up 完成或在 return 中登记顺延。
汇报：returns/zhaomaota97-website-fullloop.md + Feishu 群。agent-browser 截图为准；开工前必读 docs/together/contributing/。
```

### gagameow（黄佳佳）

```
【dev-together 2026-07-08 · gagameow】
背景：dogfooding/自举能力审计——「在 ezagent 里开发 ezagent」今天是否可行。不依赖 stable 链，可立即开工。
任务：三个面逐一验证：① 改代码库 + 提 PR——在 ezagent session 内让 agent 修改 esr-ng 仓库并提交一个真实 PR；② 产出 plugin——从内部开发一个新 ezagent 插件；③ 生成 socialware——从内部编写 + 发布 + 安装一个新 socialware。
DoD（可演示）：一份验证报告，每个面三栏——「今天能跑通什么（附证据：PR 链接 / 插件运行截图 / socialware 安装截图）/ 哪里断（复现步骤）/ 缺口在哪（结构性归因）」。跑通即贴证据，跑不通即贴断点，两者都算完成——这是审计不是修复。
汇报：returns/gagameow-dogfooding-audit.md + Feishu 群。开工前必读 docs/together/contributing/。
```

### jjkysy（姚升悦）

```
【dev-together 2026-07-08 · jjkysy】
背景：deploy-seed 车道 PR 此前被 CI 队列停摆（runner 事故，已由 #1237 解阻）挡住，pending CI re-run。
任务：deploy-seed 车道 PR——rebase 到 current main → CI re-run → 绿后请 lead 合入；顺带作为 socialware boot 时序面（sw-home 晚扫）的支持人，解答 stable 验证中冒出的 boot 时序问题。
DoD（可演示）：PR CI 全绿（precommit + check_invariants）+ rebase 到 current main + 在 PR 上留言请求合入。
汇报：returns/jjkysy-deploy-seed-lane.md + Feishu 群。开工前必读 docs/together/contributing/。
```

### zyli-developer（李震宇）

```
【dev-together 2026-07-08 · zyli-developer】
背景：stable（app.ezagent.chat）带 #1235 重新部署绿后（等 lead 宣布），主目标 socialware load/create/delete 验证需要可复跑的 E2E 场景。
任务：用 agent-browser 把 socialware 安装/卸载 E2E 场景脚本化（沉淀到 docs/e2e/，agent 可照着自动跑）：admin 登录 → session 内列出已装 socialware → 安装（hello 或 manifest import）→ 验证物化（成员出现、views 挂载，截图）→ 卸载 → 验证干净移除（无残留 rule，T4 #1221 的保证）→ M3 requires 冒烟（装依赖编排器的 socialware → 编排器自动装齐）。同时校验各步 UI 呈现。
DoD（可演示）：docs/e2e/ 新场景文档 + 全流程 agent-browser 截图链（每步一张）+ 残留 rule 检查证据；发现的问题逐条开 issue。
汇报：returns/zyli-socialware-e2e.md + Feishu 群。UI 验证 agent-browser 截图第一、日志第二；开工前必读 docs/together/contributing/。
```

### ruihuachen-designer（陈瑞华）

```
【dev-together 2026-07-08 · ruihua】
背景：stable（app.ezagent.chat）带 #1235 重新部署绿后（等 lead 宣布），需要真实用户视角的探索式玩法测试——不是脚本化 E2E，像真实用户一样玩。
任务：自由探索平台各项玩法：session、agent、socialware 体验（hello / kanban / dealscout / autoservice）、按角色名 @mention（T3 新功能）、magic-link 登录流、world UI。任何困惑、损坏或惊喜之处都记下来。
DoD（可演示）：一份非正式发现清单——试了什么 / 什么出乎意料（好的坏的都算）/ 什么坏了（附截图和大致步骤即可，不必精确复现）。
汇报：清单发 Feishu 群（或交 lead 代填 returns/ruihua-playtesting.md）。无需读代码、无需 rebase——用户视角就是价值。
```

---

本计划面向全体开发者。团队向 HTML 版见 `plan.html`。
