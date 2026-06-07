# 架构深化 —— 第二阶段：架构适应度函数（Architecture Fitness Functions）

**状态**：Codex 可自主执行的交接文档。撰写于 2026-06-07。
**仓库**：`esr-ng`，从 `origin/main` 拉出的分支。
**任务**：`docs/futures/todo.md` #25 —— 架构深化，第二阶段。
**英文对照**：[2026-06-07-architecture-deepening-phase2-fitness-functions.md](2026-06-07-architecture-deepening-phase2-fitness-functions.md)。
**前置**：第一阶段提案 `docs/notes/2026-06-07-architecture-deepening-v1.md`（PR #610 已合并）。

---

## 0. 重新定义（先读这一节）

Codex 的第一阶段提案把第二阶段定义为一系列**行为保持的重构 PR**（PR-A 拆 AdminLive、
PR-C 拆 SessionCreator……）。Allen 重新定义如下：

> **第二阶段不是重构。第二阶段是一套可执行的「架构适应度函数」——
> 即一组测试 + grep/扫描，用来揭示并量化架构债务**（冗余、临时拼凑、反模式）。
> 修复工作推到**第三阶段及以后**：每个重构 PR 把某个适应度函数的计数推向其目标值，
> 「计数命中目标 = PR 完成」—— 客观验收，而非主观的「是不是更干净了」。

这把 Allen 的两条既有原则应用到了**架构本身**：

- `feedback_systematic_fix_over_local_entropy`：不要对系统性问题做点状修补；
  先用一次扫描定位**全部**实例，再机械地一次性修完。扫描本身**就是**适应度函数。
- `feedback_completion_requires_invariant_test`：绝不能仅凭「合并 + 测试通过」就宣称完成；
  要定义一个**在架构目标未达成时会失败的测试**，那个测试就是关卡。这里，
  「违例不超过 N 个」就是关卡，第三阶段及以后把 N 逐步往下拧到目标值。

本仓库已有强先例：`mix ezagent.check_invariants`（基于 grep 的 Mix task，16 项检查）
与 `test/invariants/` 下的 ExUnit 套件（如 `uri_canonicalization_invariant_test.exs`）
已经是这个形态 —— grep + 白名单 + `# <gate>-allow: <原因>` 抑制写法。
**第二阶段就是把这个模式从「硬性不变式」推广到「架构债务计数器」。**

### PR-0 护栏是第二阶段的「子集」

第一阶段评审（ACCEPT-WITH-CHANGES）产出了一组 "PR-0" 护栏 —— 即**保护不变式**的那部分
适应度函数（effect 纪律、单写入方 + 创建唯一入口、冷重启往返、Kind.Runtime 次序、两个
关卡保持绿色）。它们是**目标=0、绝不可回退**的子集。第二阶段更宽：它**同时**交付**揭示债务**的
计数器（超大文件、裸 Home.path、重复解析……），这些的目标由第三阶段及以后从已捕获的基线
逐步往下拧，而不是恒守 0。

---

## 1. 交付物形态（关键设计决策）

### 1.1 适应度函数放在哪里

```
apps/ezagent_core/lib/mix/tasks/ezagent.arch.scan.ex     # 扫描器 Mix task
apps/ezagent_core/test/architecture/                     # ExUnit「架构测试」
  ├── arch_baseline_manifest.exs                         # 已知违例清单（数据）
  ├── oversized_modules_test.exs
  ├── raw_home_path_test.exs
  ├── spawn_chokepoint_test.exs
  ├── duplicated_resolution_test.exs
  ├── effect_discipline_test.exs        # PR-0（目标 0）
  ├── single_writer_test.exs            # PR-0（目标 0）
  └── runtime_ordering_test.exs         # PR-0（目标 0）
docs/notes/2026-06-07-arch-fitness-baseline.md           # 人读的基线报告
```

`mix ezagent.arch.scan` 是一个**源码树 grep task**（不起 BEAM 运行时），仿照
`ezagent.check_invariants`。它是 A 类开发环工具，**不是**被 dispatch 的 op
（与 `check_invariants` 同样的豁免 —— 见 `docs/notes/2026-05-24-cli-gui-parity-audit.md`）。
它打印每个适应度函数、当前计数、基线上限、以及 PASS/FAIL。

### 1.2 如何「报告」—— 基线清单（baseline manifest）

这是最重要的设计要素。每个适应度函数都有一个存在
`arch_baseline_manifest.exs`（纯数据 map）里的**基线上限 N**：

```elixir
%{
  oversized_modules_gt_1500: 5,     # > 1500 行的文件数
  oversized_modules_gt_1000: 17,    # > 1000 行的文件数
  raw_home_path_outside_core: 11,   # 绕过 UriQuery seam 的 Home.path() 调用点
  duplicated_resolve_template_class: 3,
  # PR-0 保护不变式（必须恒为 0）：
  cross_slice_set_violations: 0,
  spawn_fresh_outside_allowlist: 0,
  ...
}
```

### 1.3 棘轮规则（基线即通过 / PASSING-AT-BASELINE）

每个架构测试断言**「违例不超过 N」**，N 即清单上限：

```elixir
test "超大模块（>1500 行）数量不超过基线" do
  count = ArchScan.count(:oversized_modules_gt_1500)
  assert count <= Manifest.cap(:oversized_modules_gt_1500),
    "回退：#{count} 个文件 > 1500 行，基线上限是 #{Manifest.cap(...)}。" <>
    "引入了一个新的超大模块。拆掉它，或显式抬高上限并给出理由。"
end
```

该设计的后果：

1. **第二阶段以「基线即通过」落地。** 套件一合并即绿，因为每个上限都等于实测基线。
   第二阶段揭示并冻结债务，并不修它。
2. **这是单向棘轮。** 新违例把计数顶到上限之上 → 测试失败 → 债务无法悄悄增长。
   既有的保护不变式关卡（上限已为 0）抓**重新引入**；债务计数器抓**新增**。
3. **第三阶段及以后的验收是客观的。** 重构 PR 降低某个计数，再把上限同步下调。
   「PR-A 完成」= `oversized_modules_gt_1500` 上限 5→4 且套件绿。没有主观的「是否更干净」评审。
4. **上限只能凭清单里显式的 `# arch-cap-bump: <原因>` 才能抬高** —— 任何债务增长都成为可评审、
   有意为之的动作。

抑制写法沿用 `uri_canonicalization_invariant_test.exs`：任何以 `# arch-allow: <原因>` 结尾的行
对该计数器豁免（用于真正的结构性例外，例如 `Home` 模块本身定义 `path/1`）。

---

## 2. 适应度函数 —— 含真实基线（2026-06-07 在 `origin/main` 实测）

下列计数均由所示命令在 `origin/main` 上跑出。排除：`/test/` 路径、`_build/`、`deps/`。
"core" = `apps/ezagent_core`。

### A 类 —— 冗余（重复逻辑 / 并行实现）

#### A1. session 生成路径存在多个写入方

- **症状与原因**：单写入方 + 创建唯一入口不变式。只有被授权的唯一入口才应触达
  `SpawnRegistry.spawn_detailed/1`。散落的写入方就是 scenario-34 / #533 创建统一化的 bug 类。
- **机制（扫描）**：
  ```bash
  grep -rEn 'SpawnRegistry\.spawn(_detailed)?\(' apps --include='*.ex' \
    | grep -v '/test/' | sed 's#:[0-9]*:.*##' | sort | uniq -c | sort -rn
  ```
  ExUnit：断言调用 `SpawnRegistry.spawn*` 的模块集合是白名单（唯一入口 + 被授权的域写入方）的子集。
- **基线**：**38 个调用点，分布在 32 个模块。** 唯一入口是 `Ezagent.Kind`
  （`kind.ex:294 def spawn/2`）；合法域写入方为 `entity/agent.ex`(3)、`entity/session.ex`(2)、
  `session_creator.ex`(2)。其余约 25 个模块（含 4 个插件模板、2 个 demo seed 任务、若干
  `*/application.ex`）即工作清单。
- **目标**：把脱离唯一入口的模块数收敛到白名单。（很多是 seed/demo 任务 —— PR 中逐个分类为允许或修复。）

#### A2. `create_session/3` 的调用方

- **症状与原因**：`SessionCreator.create_session/3` 是底层单写入方。调用方应少且经授权
  （admin LV、workspace behavior、home LV、应用启动）。增长意味着新出现了一条 session 创建路径。
- **机制**：`grep -rEn '\.create_session\(' apps --include='*.ex' | grep -v '/test/'`
- **基线**：**6 个调用点，分布在 5 个模块**（`admin_live.ex` x2、`application.ex`、
  `workspace.ex`、`workspace.create_session` mix 任务、`home_live.ex`）。目前都合法。
- **目标**：稳定在 5 个模块（回退守卫，不是缩减目标）。

#### A3. 重复的 `resolve_template_class/1`

- **症状与原因**：复制粘贴的解析逻辑 —— 同一套模板类解析被实现了 3 次。应当只有一个标准解析器。
- **机制**：`grep -rEn 'defp? resolve_template_class' apps --include='*.ex' | grep -v '/test/'`
- **基线**：**3 处定义** —— `entity/agent.ex:1271`、`entity/agent_template.ex:381`、
  `plugin_liveview/agent_extensions_live.ex:126`。
- **目标**：**1**（收敛到一个域 seam，其余两处委派给它）。

#### A4. 并行的 cc/codex flavor 运行时（重复的 Template Class）

- **症状与原因**：`cc_agent.ex`（2222 行）与 `codex_agent.ex`（1009 行）把同一套 seam 形态
  （config-home 物化、凭据授予、spawn-plan、回滚、respawn）实现了两遍。这是第一阶段 §3.3 的发现，
  也是最大的重复面。
- **机制（代理指标）**：统计两模块中共享回调名的调用点；跟踪两个 Template Class 的合计 LOC。
  ```bash
  wc -l apps/ezagent_plugin_cc/lib/ezagent/template/cc_agent.ex \
        apps/ezagent_plugin_codex/lib/ezagent/template/codex_agent.ex
  ```
- **基线**：合计 **3231 行**；两者各自独立实现 `template_data_extra`、`validate`、
  `config_dir` 处理、`pty_params`、`instantiate`、`form_to_args`。（这与 A 线收敛：抽出共享的
  `Ezagent.Agent.ConfigHome` / `SpawnPlan` 同时降低重复**和**超大模块计数。）
- **目标**：随共享 seam（`ConfigHome`、`SpawnPlan`、`TemplateData`）抽出，合计 LOC 下降；
  以 LOC 阈值跟踪，不是硬计数。

### B 类 —— 临时拼凑（绕过 seam / 唯一入口）

#### B1. 绕过 UriQuery / Resource seam 的裸文件路径拼接

- **症状与原因**：`Ezagent.Home.path(...)` + 对 home 派生路径的裸 `Path.join` 是临时的资源寻址。
  Resource 统一化路线希望可寻址资源（上传、凭据、config-home、socket、日志）走单一 URI/seam。
  每个裸调用点都是未来 Resource Kind/URI 看不到的地方。**该计数器与 Resource 统一化工作收敛** —— 标注。
- **机制（扫描）**：
  ```bash
  grep -rn 'Home\.path(' apps --include='*.ex' | grep -v '/test/' \
    | grep -v 'apps/ezagent_core'
  grep -rn 'Path.expand("~' apps --include='*.ex' | grep -v '/test/'
  ```
- **基线**：
  - `Home.path(` 合计 **22** 个调用点；**core 之外 12 个**（应当走 seam 的那些）：
    `agent_bridge/token_store.ex`、`identity/application.ex`、`codex_agent.ex:892`、
    `admin_live.ex`（701、731 —— 上传）、`cc_agent.ex:1460`（注释）、`feishu/client.ex`（164、176）、
    `feishu/ws_client.ex:165`、`feishu/application.ex:176`、
    `ezagent_web/uploads_controller.ex:108`、`python/server.ex:708`。
  - `Path.expand("~` **2** 处（cc seed 任务注释 + `mcp_config_writer.ex` 的 `@default_dir`）。
- **目标**：core 之外的裸 Home.path → **0**（全部走解析后的 seam）。上传相关点
  （admin_live + uploads_controller）是第三阶段第一个缩减项（上传走 UriQuery）。

#### B2. 白名单之外的 `spawn_fresh`

- **症状与原因**：不变式 —— 受管成员/团队物化必须走 `spawn_from_template_content`，绝不走
  `spawn_fresh`（scenario-34 的 bug：`spawn_fresh` 造出没有 CLI/PTY 的裸 Kind）。`spawn_fresh`
  是底层原语；只有 `Entity.Agent`（定义）+ 调和器路径可用。
- **机制**：
  ```bash
  grep -rEn 'spawn_fresh(_member)?\(' apps --include='*.ex' | grep -v '/test/' \
    | grep -vE ':[0-9]+:\s*#'
  ```
- **基线**：**5 处引用**；真正的*调用*为 `entity/agent.ex:182`（调和器允许的自调用）与
  `tools.ex:564`（`spawn_fresh_member`，定义在 `tools.ex:293` 的内部 `defp`）。41 处
  `spawn_from_template_content` 表明模板内容路径占主导 —— 良好。两处 `spawn_fresh` 调用即审计面。
- **目标**：**0 未授权**；当前两处调用要么进显式白名单并附理由，要么证明 `tools.ex` 的
  `spawn_fresh_member` 实际走的是模板内容路径。PR-0 不变式 —— 绝不可增长。

#### B3. 直接跨 slice 状态访问 / `:all_slices` 逃生口

- **症状与原因**：不变式 #18 —— 兄弟 slice 读取须通过 `reads_sibling_slices/0` 显式声明；
  `:all_slices` 被禁。
- **机制**：`grep -rn ':all_slices' apps --include='*.ex' | grep -v '/test/'`
- **基线**：**3 处出现，0 违例** —— 两处在注释里（`behavior.ex:454`、`kind/runtime.ex:182`
  描述该禁令），一处是有据可查的读自身 slice（`system_principal/catalog.ex:271`，
  `ctx[:all_slices][:api_keys]` 读自己的 slice）。`reads_sibling_slices/0` 在 **2** 个模块中声明。
- **目标**：**0** 未授权 `:all_slices`。已为 0 —— 纯回退守卫。

### C 类 —— 反模式（超大模块 / 上帝函数 / 缺失关卡）

#### C1. 超大模块（LOC 阈值）

- **症状与原因**：Ousterhout 深模块 / 上帝模块反模式。阈值设为 **1500 行**（硬）与
  **1000 行**（观察）。每个超大文件把多个接口藏在一个模块后 —— 第一阶段 §3 的发现。
- **机制（扫描）**：
  ```bash
  find apps -path '*lib*' -name '*.ex' | xargs wc -l \
    | awk '$1>1500 && $2!="total"' | sort -rn
  ```
- **基线**：
  - **> 1500 行：5 个文件** ——
    | 行数 | 文件 |
    |---:|---|
    | 3217 | `ezagent_plugin_liveview/.../admin_live.ex` |
    | 2222 | `ezagent_plugin_cc/.../template/cc_agent.ex` |
    | 1983 | `ezagent_domain_instance_message/.../session_creator.ex` |
    | 1886 | `ezagent_domain_instance_message/.../orchestrator/tools.ex` |
    | 1798 | `ezagent_domain_instance_message/.../behavior/chat.ex` |
  - **> 1000 行：17 个文件** —— 上述 5 个，外加：
    | 行数 | 文件 |
    |---:|---|
    | 1459 | `ezagent_core/.../kind/runtime.ex` |
    | 1422 | `ezagent_core/.../behavior.ex` |
    | 1395 | `ezagent_domain_workspace/.../behavior/workspace.ex` *（第一阶段清单遗漏）* |
    | 1363 | `ezagent_domain_instance_message/.../entity/agent.ex` |
    | 1351 | `ezagent_domain_instance_message/.../entity/session.ex` |
    | 1117 | `ezagent_domain_instance_message/.../application.ex` *（第一阶段清单遗漏）* |
    | 1076 | `ezagent_core/.../kind.ex` |
    | 1071 | `ezagent_domain_instance_message/.../orchestrator/mcp_server.ex` |
    | 1023 | `ezagent_core/.../capability.ex` |
    | 1010 | `ezagent_domain_external_mirror/.../behavior/external_mirror_worker.ex` *（第一阶段清单遗漏）* |
    | 1009 | `ezagent_plugin_codex/.../template/codex_agent.ex` |
    | 1004 | `ezagent_domain_external_mirror/.../behavior/external_mirror.ex` *（第一阶段清单遗漏）* |
- **目标**：`gt_1500` 上限 5 → 第三阶段及以后逐步拧到 0。`gt_1000` 上限 17 → 观察（不准新入）。
  注意：第一阶段清单漏了 4 个文件（workspace.ex、application.ex、external_mirror{,_worker}.ex）——
  第二阶段捕获**完整**集合。

#### C2. 上帝函数（每个超大模块的 def 计数代理）

- **症状与原因**：`def/defp` 极多的模块做了太多事；在函数粒度跟踪同一反模式，给第三阶段及以后一个
  独立于纯 LOC 的逐模块缩减信号。
- **机制**：对每个超大模块 `grep -cE '^\s*(def|defp) ' <file>`。
- **基线**：`admin_live.ex` **186**、`cc_agent.ex` **103**、`tools.ex` **83**、
  `session_creator.ex` **78**、`capability.ex` **65**。
- **目标**：随每个模块拆分而 def 计数下降；逐文件记入清单，与 C1 一同棘轮。

#### C3. 跨 slice 的 `{:set}` / effect 纪律（PR-0）

- **症状与原因**：不变式 #18 effect 纪律 —— 任何 Behavior handler/helper 都不得做跨 slice 的
  `{:set, :other_slice, ...}`，也不得在 `(state, args, ctx) -> {data, [effect]}` 文法之外做有副作用的写。
  handler 只能 `{:set, <自身 slice>, ...}`。
- **机制**：枚举 `{:set, :<slice>, ...}` effect 并断言每个模块只 set 自己声明的 `state_slice`
  （ExUnit 走 AST / grep + 逐模块 slice 映射）。裸扫描：
  ```bash
  grep -rEn '\{:set,\s*:[a-z_]+,' apps --include='*.ex' | grep -v '/test/'
  ```
- **基线**：合计 **118** 处 `{:set, :slice, ...}` effect。适应度函数断言其中**跨 slice 为 0**
  （每个 set 指向发出模块自身的 slice）。第二阶段捕获逐模块 slice 白名单；被关卡的数字是*跨 slice 违例*数。
- **目标**：跨 slice 违例 **0**（PR-0；绝不可增长）。

#### C4. 变更类动作缺失 cap 检查（PR-0）

- **症状与原因**：CapBAC 唯一入口 —— 每个变更类动作都走 `Kind.Runtime` authz
  （`authz_check → workspace_isolation_check → invoke`，次序不可乱）。带变更 effect 但未声明
  `required_caps` 的 Behavior 动作就是漏洞。
- **机制**：对 Behavior 注册表做 ExUnit —— 每个声明了变更 effect 的动作都必须声明 `required_caps`。
  （已有 `behavior_required_caps_action_invariant_test.exs` —— 在 arch 套件里扩展/别名复用，不要重复造。）
- **基线**：既有不变式测试通过 → **0 已知违例**。
- **目标**：**0**（PR-0；由既有关卡保护，为完整性在 arch 清单中体现）。

#### C5. Kind.Runtime 次序（PR-0）

- **症状与原因**：`handle_dispatch/4` 必须按 `authz_check → workspace_isolation_check → invoke`
  执行，不可乱序/跳过/重入（不变式 #17 —— 不得从 `target_ownership_check/2` 或
  `event_to_payload/1` 重入 dispatch）。
- **机制**：ExUnit 断言 `kind/runtime.ex` 中三阶段调用次序（AST / 有序 grep）+ 既有重入不变式。
- **基线**：次序完好 → **0 违例**。
- **目标**：**0**（PR-0）。

#### C6. 冷重启 respawn 往返（PR-0）

- **症状与原因**：spawn → 快照 → 冷重启 → 级联，必须重新解析 + 重新授 cap 且完全一致
  （#110/#113/#114 类）。这是*行为型*适应度函数，不是 grep —— 应作为 `MIX_ENV=test` 下的
  ExUnit 往返测试。
- **机制**：ExUnit（仅测试环境）spawn 一个模板化 session、快照、模拟冷重启、断言解析后的 cap +
  成员集合完全一致。复用既有冷重启测试夹具（若有）。
- **基线**：假定绿（既有 `mix ezagent.check_invariants.lifecycle` 覆盖 lifecycle 类）。
  第二阶段补上显式往返断言。
- **目标**：**0** 漂移（PR-0）。

---

## 3. 第二阶段 → 第三阶段及以后的映射

每个第三阶段及以后的重构 PR 现在由**它降低哪个适应度函数计数**来定义，「完成」=
计数及其清单上限双双降到目标且套件保持绿。Codex 原来的 PR-A/B/… 变为：

| 第三阶段及以后 PR（出自第一阶段 §6） | 它驱动的适应度函数 | 计数变化 |
|---|---|---|
| **PR-A** 拆 AdminLive（§3.1） | `oversized_gt_1500`（admin_live 3217）+ C2 def 计数（186） | gt_1500 上限 5→4 |
| PR-B AdminLive compose/invite/routing | C2 admin_live def 计数 | def 计数下降 |
| 上传走 UriQuery seam | B1 core 外裸 Home.path（admin_live 701/731 + uploads_controller 108） | 12→9 |
| PR-C SessionCreator listing/resolver | （预备）—— 暂无计数 | — |
| PR-D/E SessionCreator team/rollback | `oversized_gt_1500`（session_creator 1983） | gt_1500 上限 →3 |
| PR-F/G Orchestrator Mcp/Tools 拆分 | `oversized_gt_1000`（mcp_server 1071）+ `oversized_gt_1500`（tools 1886） | 上限下降 |
| **PR-H** cc/codex ConfigHome + SpawnPlan | A4 合计 LOC + `oversized_gt_1500`（cc_agent 2222）+ B1（codex_agent 892） | gt_1500 上限降；A4 LOC 降 |
| 合并 `resolve_template_class` | A3 重复解析 | 3→1 |
| PR-I Behavior.Chat helpers | `oversized_gt_1500`（chat 1798） | gt_1500 上限降 |
| PR-K/L Capability / Behavior 拆分 | `oversized_gt_1000`（capability 1023、behavior 1422）+ C2 capability def 计数（65） | 上限降 |

### 推荐的第三阶段首个 PR + 次序

1. **首选：PR-A —— AdminLive 抽出 session-context + rehydrate-flash。**
   单文件最大（3217），不变式风险最低（UI，不碰 CapBAC 核心），纯机械。驱动
   `oversized_gt_1500` 5→4。这是第一阶段评审的推荐，也是最安全的客观胜利。
2. **Capability 拆分要在 cc/codex 共享运行时 PR（PR-H）之前。** cc/codex 的
   ConfigHome/SpawnPlan 抽取（PR-H）涉及安全敏感（config-home 拷贝、secret relpaths、授予铸造）。
   先拆 `Capability`（`Normalize` / `Match` / `Scope`，capability.ex 1023 行）能给 PR-H 一个
   干净、已审计的 capability seam 来构建凭据授予路径，而不是在仍然单体的 Capability 之上抽取共享凭据逻辑。

---

## 4. Codex 执行说明（自主）

**范围**：构建第二阶段套件 + 清单 + 扫描器。本次工作中**不做任何第三阶段重构**。以基线即绿落地。

1. 创建 `mix ezagent.arch.scan`，仿照
   `apps/ezagent_core/lib/mix/tasks/ezagent.check_invariants.ex`（源码树 grep，不起 BEAM，
   A 类开发环工具 —— 保持 `mix ezagent.arch.*`，**不要**迁到被 dispatch 的 `mix ezagent`）。
   §2 每个适应度函数一个函数，各返回 `{name, count}`。
2. 创建 `apps/ezagent_core/test/architecture/arch_baseline_manifest.exs`，上限设为 §2 的
   **实测基线**（这些是 2026-06-07 在 `origin/main` 上的权威值；若 `main` 已变动，用 §2 命令重测并采用新值）。
3. 每个适应度函数一个 ExUnit 测试，断言 `count <= cap`，仿照
   `apps/ezagent_core/test/invariants/uri_canonicalization_invariant_test.exs`
   （白名单 + `# arch-allow: <原因>` 抑制写法）。PR-0 函数（B2、B3、C3、C4、C5、C6）断言 `== 0`。
4. 写 `docs/notes/2026-06-07-arch-fitness-baseline.md` —— 人读的债务清单（§2 各表），由本交接文档交叉链接。
5. 在 ARCHITECTURE.md Decision Log（附录 B，取下一个顺序号）追加一条：
   「架构适应度函数 —— 第二阶段债务计数器，由第三阶段及以后棘轮；新违例使 CI 失败；
   抬高上限需 `# arch-cap-bump:`。」

**验收（客观）**：
- [ ] `mix ezagent.arch.scan` 能跑，打印每个适应度函数 + 计数 + 上限 + PASS。
- [ ] `mix test apps/ezagent_core/test/architecture/` 在基线处全绿。
- [ ] `mix ezagent.check_invariants` 绿（不变）。
- [ ] `mix ezagent.check_invariants.lifecycle` 绿（不变）。
- [ ] 基线清单上限 == §2 实测数；基线说明已提交。
- [ ] 未修改 `apps/*/lib` 下任何生产 `.ex`（仅套件 + 清单 + 文档）。

**约束**：
- Codex 仅做静态评审（`feedback_codex_companion_no_mix`）：companion 无 `mix deps`；
  评审静态读源码，不跑 `mix`。
- 仅在 `MIX_ENV=test` 下测试；绝不碰 dev/prod 迁移或 Docker。
- 双语文档（`feedback_bilingual_docs_convention`）：本 `.md` 与 `.zh_cn.md` 对照保持同步。

---

## 5. 小结 —— 第二阶段揭示并量化了什么

| 适应度函数 | 类别 | 基线 | 目标 |
|---|---|---:|---|
| > 1500 行的文件 | 反模式 | **5** | 0（棘轮） |
| > 1000 行的文件 | 反模式 | **17** | 观察 |
| admin_live def 计数 | 反模式 | **186** | 降低 |
| cc_agent def 计数 | 反模式 | **103** | 降低 |
| 脱离唯一入口的 `SpawnRegistry.spawn*` 模块 | 冗余 | **32 中约 25** | 白名单 |
| `create_session/3` 调用方模块 | 冗余 | **5** | 稳定 |
| 重复的 `resolve_template_class/1` | 冗余 | **3** | 1 |
| cc+codex Template Class 合计 LOC | 冗余 | **3231** | 降低 |
| core 外裸 `Home.path()` | 临时拼凑 | **12** | 0 |
| `Path.expand("~` | 临时拼凑 | **2** | 0 |
| 未授权 `spawn_fresh` 调用 | 临时拼凑（PR-0） | **2** 处（审计） | 0 |
| 未授权 `:all_slices` | 临时拼凑（PR-0） | **0** | 0 |
| 跨 slice `{:set}`（118 处 `:set` 中） | 反模式（PR-0） | **0** | 0 |
| 变更类动作缺失 cap 检查 | 反模式（PR-0） | **0** | 0 |
| Kind.Runtime 次序 / 重入 | 反模式（PR-0） | **0** | 0 |
| 冷重启 respawn 漂移 | 行为型（PR-0） | **0** | 0 |

PR-0 集（目标 0，绝不可回退）：effect 纪律、单写入方 + 创建唯一入口、冷重启往返、
Kind.Runtime 次序、两个关卡绿。揭示债务的计数器（由第三阶段及以后逐步拧低）：超大模块、
def 计数、裸 Home.path、重复解析、cc/codex 合计 LOC。
