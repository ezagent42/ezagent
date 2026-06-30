# kanban / socialware 开发中的坑 + 待补决策

> 读者：接手 kanban / socialware 方向、或基于这套机制开发的工程师。
> 本文记录 kanban 团队开发流 PR（pm-coordinator + dev-together 接力）开发期间踩的坑、
> 已解 / 已接受 / 待 Allen 拍板的决策。是 hard-won 经验的留档，不是设计权威（设计看
> ARCHITECTURE.md / GLOSSARY.md Decision Log）。

---

## Part A — 开发中遇到的坑（已解 / 操作规矩）

### A1. 工具链：mise OTP27 / Elixir 1.18，隔离跑
- 全 gate 必须在 umbrella root + `mise exec` 的 pinned OTP27 / 1.18.4 下跑。per-app 单独跑会因兄弟插件没加载假失败（如 `{:unknown_flavor, "cc"}`、github sibling 未加载）——test body 多带 "run from umbrella root" 守卫。
- **format 工具链 skew**：pinned 1.18.4 下全仓 `mix format --check-formatted` 会报若干 main 存量文件未格式化（与 upstream/main byte-identical、main 自己也过不了）。这是版本 skew + 存量债，**feature PR 不吸收**（formatter-noise 政策）；自己的新文件保持 format-clean。

### A2. e2e harness：真浏览器 + 真渠道，每步截图
- e2e 用 `cdp.py` 驱动 headless Chrome（独立 profile，端口 9333），**每个有意义步骤截图**（配置→chat→操作→结果），不是只截最终。拒绝单元 stub 当 e2e。
- 起 dev server：**不加 `-sname`**、`NO_DISTRIBUTION` 不设（让 runtime 自分布 `ezagent_runtime@127.0.0.1`，epmd 没起要先起）、cwd 配 worktree 根、同源 built bundle（去掉 vite watcher）、fresh 隔离 DB（用后 drop）。
- **用后必 `git checkout config/dev.exs`**（e2e 临时改了 budget/cwd）。

### A3. cc 冷启 budget 家族（两个旋钮都要 bump）
- 串行 materialize 两个 cc-headless agent（pm 然后 dev）时，**`activate_budget_ms` 和 `transport_join_timeout_ms` 两个都要 bump**（默认各 ~30s，cc 冷启真慢 50-85s）。只 bump 一个 → 第二个 agent 撞 `:activate_timeout`（act5 卡 dev-together 的根因，T10/T11/T13 两个都 bump 后双双 JOIN）。

### A4. World UI headless 脆 + 投递模型
- World UI（LiveView + React SPA）在 headless e2e 下偶发脆（mount 时序）。RPC 只读取证（psql / routing table）比纯 UI 断言稳。
- **投递模型**：agent 成员只被「@mention 了它」的消息唤醒，user 收全部。所以 agent 之间的接力**不能靠对方记得 @你**——见 B3 / dev→pm relay-back 路由规则。

### A5. agent 内跑 e2e 泄漏 CLAUDECODE
- 在一个 agent（cc）里跑 e2e、又起子 cc，父进程的 `CLAUDECODE` / `CLAUDE_CODE_*` env 会泄漏进子进程，污染判定。起 e2e 子进程前清理这些 env。

### A6. 杀进程：精确点名 PID，绝不 awk 树遍历
- 清理 e2e 残留（beam / headless chrome / claude PTY）**必须按保存的精确 PID 点名杀**。曾用 awk 树遍历推导"后代 PID"误杀了自己的 session 进程。教训深。

### A7. 测错方向的代价（dev-together 不操作板）
- T10 一度让 dev-together 直接 `dispatch` 改看板，撞 CapBAC denied，误判成"dev 需要 board caps"。**实际 dev-together = 只生成产物（artifact），板的推进 + github 都是 pm（kanban agent / lead）干的**。纠正后（T11/T12）CapBAC 审计 dev→board=0，证伪了"dev 需 board caps"。教训：先吃透角色职责再测。

### A8. world_live.ex 撞 gt_1000 arch gate
- World UI 文件涨过 1000 行触发 `oversized_modules_gt_1000` 硬零 gate。按先例抽内聚块到 sibling 模块（如 `Ezagent.World.Jsonable` / `Ezagent.World.Routes`，thin-delegate、public API 不变）压回 <1000。rebase 时我和 main 各自改 world_live.ex 在三方合并里叠加过线，也是这么抽块解的。

### A9. rebase 必先扫库找 main 既有的通用路（别自己 fork 一条）（2026-06-30 教训）
- rebase / 接着 main 干时，**先扫库**看你要建的「通用机制」main 是不是已经有了。本轮的反面：dev-together 一度被实现成一个**独立 plugin**（`ezagent_plugin_dev_together`，passive native + dive/return behaviors）+ 自己的 `DevTogetherSeed`，pm 也在 kanban 自己 `roles/0` + `PmCoordinatorSeed` 里 seed——两边把「recipe + 模板 seed + grant」这套组合**逐字 fork**了两份。正解是 main 早有的 domain.agent 原语（`DefaultAgentSeed` / `SessionAgentMaterialize` / `GrantRecipeCaps`），把通用 cc-headless agent 的 recipe 收口到**一个**统一入口 `DefaultRecipes` + `DefaultRecipeSeed`（domain_agent，非 plugin），删掉空壳 plugin。教训：通用 agent 配置 = role-as-data 经统一入口，**不是**「每来一个 agent 建一个 plugin」；rebase 时撞到的命名/路径冲突往往是「main 已经做了你正要做的事」的信号——停下来扫库，别机械 rebase 自己那份 fork。`FF-1 cross_file_duplicate_fn_groups` arch gate 就是防这种 fork 堆积的。

### A10. cc-flavor 模板 seed 必须挂 cc plugin 的 `after_boot`（boot-order）（2026-06-30）
- 一个默认 role-agent 要两样东西：recipe ConfigObject（flavor 无关）+ `cc × <role>` AgentTemplate（**需要 cc flavor 的 spawn fn**）。这两样在不同 boot 阶段就绪，所以 `DefaultRecipeSeed` 拆成两半、**挂两个不同的 boot 点**：
  - recipe-seed（`seed_all/0`）→ `EzagentDomainAgent.Application.start/2`（domain_agent boot 最晚点，Repo + ConfigStore 已起；纯 config、不需 module 也不需 spawn fn，这么早跑安全）。
  - template-seed（`seed_templates_all/0`）→ **cc plugin 的 `after_boot`**（`EzagentPluginCc.Application.after_boot`，在 `Workspace.Loader.load_all/0` 发布 cc flavor + 它的 template spawn fn **之后**）。
- **坑**：若把 template-seed 也放进 domain_agent `start/2`，此刻 cc spawn fn 还没注册 → `{:no_spawn_fn, "template"}`。它要 mirror 既有的 cc-orchestrator AgentTemplate seed（也在 cc `after_boot`）。两半都 `:test` skip + boot-safe（失败降级 warning + telemetry，绝不 crash boot）。

### A11. arch / 不变式 gate 单独跑会假失败——必须全套从 umbrella root 跑（2026-06-30）
- 这是 A1「per-app 单独跑假失败」的具体放大：`mix ezagent.arch.scan` / `check_invariants` 这类**架构 gate test 单独跑**（只跑某个 app、或只跑那一个 test 文件）会因兄弟 app / 全 manifest 没加载而**假失败/假阴性**（如跨文件重复扫不到全量、flavor/sibling 未加载）。结论：判断 gate 红绿**只认全套**——`mise exec … mix test` + 各 `mix ezagent.*` 在 umbrella root 全跑；别拿单独跑的结果下「过了 / 没过」的判断。

---

## Part B — 待补决策 / surface（待 Allen / 后续）

### B1. session participation `send` cap 不 durable（reliability，建议优先）
- 现象：pm/dev 的 session participation `send` cap 间歇 denied（grant 后过一会儿 `:unauthorized`，re-join 刷新 cap 才恢复）。dev 的 return 一度撞 `:unauthorized`。
- 疑因：`mount_participation_caps` 在 snapshot / reconcile 后不 durable。**独立于 routing**（路由本身对，cap 刷新后就通）。
- 待定：让 participation cap 跨 snapshot/reconcile durable。

### B2. attach_artifact payload 鲁棒性（已加 pm-skill 指引缓解）
- 现象：pm `attach_artifact` 成功（板 artifacts []→非空、granted），但 artifact map 字段全 nil（T13）。机制没问题（T11 带完整内容成功），是 pm 大脑这一跑构造 args 没填字段。
- 已做：pm-coordinator skill「接力」节加明确指引「必填 `ref` / `tool` / `kind`」。
- 待定：是否在 handler 侧加 arg 校验（attach 空内容时 reject / warn），别只靠 prompt 鲁棒性。

### B3. forward pm→dev handoff 仍受 @mention fan-out
- dev→pm 的 relay-back 已做成 sender-locked 路由规则（T12/T13，稳）。但**反方向 pm→dev 的派活 handoff 仍靠 @mention**，而 CLI/agent 节点发的 @mention 不解析 → fan-out 到全 member，dev 一度误读 fan-out 的任务副本 stood down。
- 待定：forward 派活是否也做成路由规则（pm 派给 dev 时 wire 一条 pm→dev 的 forward 路由），或修 agent 节点 @mention 解析。

### B4. dev-together skill 的 agent return 渠道（owner 保护）
- dev（agent）做完要用 `mix ezagent session send` 投 return，但 `dev-together` skill 没教这条 agent 侧渠道（人类直接 chat，agent 需 CLI verb）。e2e 里 dev 大脑自己探到 `session send --help` 才发出。
- 待定：`.claude/skills/dev-together/**` 有 owner-only CI 保护（allenwoods），这条 doc 补丁留 owner 落。

### B5. agent 配置 UI（后续开发）
- 当前 pm/dev 的 role/recipe/cap 经**代码 seed**落地：通用 cc-headless agent（pm / dev-together）的 recipe + 模板经 `Ezagent.Agent.DefaultRecipes` + `DefaultRecipeSeed` 统一入口（2026-06-30 refactor 后，已不在 plugin roles/0；`DevTogetherSeed` 已删、`PmCoordinatorSeed` 瘦身到只剩 board-scoping）；plugin 自身 native agent（`kanban-manager`）仍在 kanban `roles/0`。UI 可配的只有 bind_session 面板 +（会话内）kanban tab。
- 待开发 UI：role recipe 编辑、cap grant / board-scoping 配置、materialize 触发——见 `docs/guide/agent-plugin-configuration.md`。

### B6. surface G — materialize 不 auto-join 会话成员（已接受）
- materialize 只 spawn + grant caps，不把 role-agent auto-join 进被绑会话。**已接受为设计内**（手动 invite）。auto-invite 留后续脚本，不阻塞。

### B7. finding D — 9 阶段是嵌套子节点
- kanban 的 9 阶段 stage 链是**嵌套子节点**，不是"单节点走 9 个 stage"。根节点钉死 `positioning`，pm 试图把根节点 `set_stage → issue` 被业务守卫 fail-closed（`stage_order_violation`，CapBAC granted 但 handler 正确拒）。文档化清楚，别误以为单节点 9-stage。

### B8. nav_surfaces / session_tabs 搬 World 层（layering 决策，2026-06-30，已落地）
- **决策**：plugin 的 World-UI surface callback `nav_surfaces/0` + `session_tabs/0` **不再是 core `Ezagent.Plugin` 契约 callback**——搬到 World 层。理由：它俩是纯 **World-UI 概念**（左栏一级 nav 入口 / 会话内 Layer-3 tab），唯一消费方是 world shell；core 是 transport/runtime 层，不该认识「侧栏」。
- **怎么落**：World 的 `Ezagent.World.UISurfaceProvider` 用 **duck-type** 读——枚举已装 plugin（`PluginRegistry.list_all/0`），`function_exported?/3` 守卫后调 plugin 的 **plain public 函数** `nav_surfaces/0` / `session_tabs/0`，每条 entry 过 read-time `valid_nav_surface?/1` / `valid_session_tab?/1`（fail-closed，坏 entry 跳过不 crash UI）。plugin **不 require** `@behaviour world`——否则逼出一条 plugin→world 反向 compile 箭头（world 在 plugin 之上）。所以 plugin 的 compile graph 对 `ezagent_plugin_world` 仍零依赖。
- **边界**：`config_surface/0`（喂 `/plugins` 配置页）**仍是 core callback**（Allen 既有，与侧栏无关，没搬）。kanban 这边：`nav_surfaces/0` 早已 demoted（A 段无关、B 段 B5 提的「板=agent 按 role 过滤」），本次连 plain 函数也删；`session_tabs/0` 留着（会话内看板 tab），现由 World duck-type 读。
- **教训**：判断一个 callback 该住哪层 = 看**唯一消费方在哪层**（P9「读什么数据决定 tier 归属」的 UI 版）；一个只有 world 用的东西放进 core Plugin 契约，是把 UI 概念漏进 transport 层。

### B9. 其它待补
- **recipe-evolution gap**：role recipe 改了之后，已 materialize 的 agent 怎么 reconcile（当前没有热更新路径）。
- **#1097 cwd-validate 正交**（已确认）：pm/dev 走 template-seed / by-role materialize，不经 `file_flavor_template` 那条唯一 `validate_project_cwd` 路径，无需配 `EZAGENT_ALLOWED_CWD_ROOTS`。若未来 pm/dev 改走 operator create-agent 路径，需重审。
- **cc cold-start budget 默认值**：`activate_budget_ms` 默认对串行 materialize 太紧（见 A3），是否调默认值待定。
