# Ezagent Rule-Gate(层级升级闸门)设计

- **日期**:2026-06-29
- **状态**:设计已批准,待写实施计划(writing-plans)
- **载体决策**:方案 B —— 两层拆分(薄「路由闸门 skill」+ 厚「规则库 skill `ezagent-developer`」)
- **目标仓**:ezagent42/ezagent(Elixir/Phoenix 平台仓)

---

## 1. 背景与真实痛点

症状:实施方向错误频发,本质是「在比需求更重的层去改动」。ezagent 的扩展机制有一条由轻到重的链:

```
config → session/orchestrator(运行时,用户在 session 里用 orchestrator 直接改/加)→ plugin → domain → core
```

两类高频错误:
- **错误①**:本该加个 plugin 就满足的,最后改到了 core 和 domain。
- **错误②**:本该改 config、或用户直接在 session 里用 orchestrator 就能完成的,最后却做成了一个 plugin。

原假设是「规则太多 + 索引不全 + 部分过时矛盾,导致 AI 找不到 / 找到错的」。经只读测绘后**修正**:规则其实已 ~80% 集中在一个 skill,真痛点更精确(见 §3)。

面向人群:**不熟整体架构、用 AI 改码的新开发者**——核心防"乱改 / 改错层";同时把"解释 + 纠偏"做完整。

---

## 2. 测绘结论:治理来源现状(只读盘点)

按职能(非文件位置)分五类:

| 类 | 来源 | 性质 |
|---|---|---|
| ① 真·权威源(规则定义处) | `.claude/skills/ezagent-developer/`:SKILL.md(导航)+ 12 个 references(~2146 行):`design-principles.md`(P1-P27,5 组)、`architecture-invariants.md`(20 条 + CI gate)、`capbac.md`/`lifecycle.md`/`new-contract.md`/`three-tier-structure.md`/`anti-patterns.md`/`how-to-recipes.md`/`debug-recipes.md`/`ui-contract.md`/`slice-and-snapshot.md`(弃用)/`pointer-index.md` | **已高度集中** |
| ② 权威 rationale + 决策档案 | `ARCHITECTURE.md`(3359 行,Allen 维护、只读)+ `GLOSSARY.md`(Decision Log #1–#154 + 术语表 + 消歧) | 教学论证 + 历史 |
| ③ 入口 / 启动 checklist / 指针 | `CLAUDE.md`(每 prompt 加载,纯指针)、`README.md`、`CONTRIBUTING.md`、`IMPLEMENTATION_ROADMAP.md`(phase 种子)、`AGENTS.md`(纯 Phoenix 通用、独立无重叠) | **过时最多** |
| ④ 强制 gate(真会跑) | `scripts/hooks/sub-step-gate.sh`(PreToolUse,commit/tag 前 `format+test+check_invariants`,exit 2 阻断)、CI `ci.yml`、`mix ezagent.{arch.scan,doc.scan,check_invariants,check_invariants.lifecycle}`、`protect-dev-together-skill.yml` | 提交期强制 |
| ⑤ per-phase 规格 + how-to | `docs/phase-specs/`(phase0–7,当前 phase7)、`docs/guide/`、`docs/onboarding/`、`docs/architecture/`、`docs/scenarios/`(35 条 E2E) | 文档 |

---

## 3. 诊断:三个根因

**根因 1(最致命)——缺「最轻层」决策路由,而且恰恰缺最轻的两层。**
现有 `P9「读什么数据决定层级」` + `three-tier-structure.md` 只覆盖 **core/domain/plugin** 三层的横向归属,**完全不覆盖** `config` 和 `session/orchestrator 运行时`。整条由轻到重的链「在 `ARCHITECTURE.md` 里没有任何显式文字表述,只通过反例隐含展示」。
- 错误①:有 P9 但要 AI 自己推理,没反向决策树兜底。
- 错误②:**无解**——"运行时 orchestrator 到底能改什么"完全没文档化,散在 `apps/ezagent_domain_session/lib/ezagent/orchestrator/tools/*.ex` 代码里;AI 看不到运行时这条路,自然往 plugin 跳。

**根因 2 —— 入口分裂、内部无索引。** AI 第一跳是 `CLAUDE.md`(只是指针,且不指向任何决策路由,因为它不存在);真权威在 skill,而 skill 自身也缺中央索引(无 CI-gates registry、无 decision tree,references 间靠手工交叉引用)。

**根因 3 —— 顶层指针过时 / 自相矛盾(降低信任、主动误导)。** 实锤:
- `CLAUDE.md` 教 `use Ezagent.Behavior`,但 2026-05-29 起开发者表面已是 `use Ezagent.Lifecycle`(前者降为 INTERNAL ENGINE,Phase C gate 硬拒绝开发者层用它)——CLAUDE.md 在教一个会被 gate 拦下的写法。
- `CLAUDE.md` 指 `references/new-contract.md`,但它已是 engine 内部,应指 `references/lifecycle.md`。
- `CLAUDE.md` / `IMPLEMENTATION_ROADMAP.md` 说"8 条硬不变式",实际 P1-P27 + 20 条不变式。
- `README.md` 仍写"Phase 0 complete"(现 phase7);`GLOSSARY` Decision #99 的 `init_slice` 已被 Lifecycle 禁用却未标注被取代;`CONTRIBUTING` 硬 gate 清单不全。

---

## 4. 设计目标(对照用户六条)

1. AI 容易发现的「统一入口」。
2. 进入后有条理、够快地定位当前任务对应规则——尤其前置一个「决策/路由」闸门:拿到需求先判断「满足它的最轻的层是哪层」再动手。
3. 规则整合成唯一实时来源(skill 成权威,旧文件逐步瘦身 / 被替代)。
4. 核心开发者(人)方便维护、修改这套规则。
5. 人性化:机制面向 AI agent,但收尾的总结要用对人友好的语言讲清「做了什么、为什么这么做、挡下了哪些违规」。
6. 未来 ezagent 再迭代可持续复用。

---

## 5. 核心模型:层级升级闸门(Layer-Escalation Gate)

挂在 **brainstorm 时机**(任何 ezagent 改动需求进 brainstorm 即启动):

**Step 0 —— 先定 E2E 验收**:先问"什么 E2E flow 能证明它成了"。复用现有 `docs/phase-specs/*/VERIFICATION.md` / `e2e-parity/FLOWS.md` + dev-together 的 demonstrable-DoD 文化。

**Step 1 —— 由轻到重的升级阶梯,每层"被证伪"才准往上爬**:

```
L0 config           ┐
L1 session/运行时    ┘ 不动代码,先用配置 + orchestrator 工具去【实验】能否让 E2E 过 → 过则打住
L2 plugin           — 运行时走不通,才尝试 plugin → 过则打住
L3 domain / core    — plugin 也不行,才进最重的层
```

实验力度 = **混合(论证优先,可行则真跑)**:AI 先用证据(列出可用的 config 旋钮 / orchestrator 工具)判最轻层能否满足;若**看起来可行**,必须**真跑一遍**运行时实验让 E2E 过才能收;若**显然不可能**,记一条书面理由即可升级。

这一步把错误②从"无解"变"有解":阶梯强制先试最轻两层,且用 E2E 当客观裁判,不靠 AI 拍脑袋。

**Step 2 —— 两个面向人的输出**(详见 §9):实时纠偏 + 架构视角解释。

---

## 6. 组件构成(三件套:内容 / 在场 / 兜底)

```
ezagent-rule-gate skill      →  内容(决策树 + 运行时能力表 + 解释模板)
CLAUDE.md 一句 always-loaded  →  每个 prompt 都在场的 why/how 指针
PreToolUse chokepoint hook    →  改代码那一刻的确定性、安静的兜底 + 纠偏
```

### 6.A 新建薄 skill `ezagent-rule-gate`

- `SKILL.md`:触发 description 写成"**决定 ezagent 改动方向 / 选哪一层 / brainstorm 一个 ezagent 改动时**"触发;正文 = §5 升级阶梯 + §9 两个输出契约。**保持薄**,深内容下沉到 references。
- `references/layer-decision.md`:**反向决策树**(config→运行时→plugin→domain→core),每层带具体 go/no-go 判定问题 + 10–20 个真实需求走查样例;**链接**到 `ezagent-developer` 的 P9 / `three-tier-structure.md` / `how-to-recipes.md`,**不复制**。
- `references/runtime-capability-map.md`:**当前全仓缺失、价值最高的新产物**——"session/orchestrator 运行时不动代码能改什么"边界表(member / rule / legend / template 工具、`Ezagent.Routing.RuleStore`、`Ezagent.AppSettings` 等),从 `apps/ezagent_domain_session/lib/ezagent/orchestrator/tools/*.ex` 与 `behavior/orchestrator_admin.ex` 提炼。**直接补上错误②的盲区。**
- `references/explain-template.md`:§9 收尾解释的中文模板。

命名遵循项目约定(kebab-case、`ezagent-` 前缀,对齐 `ezagent-developer` / `ezagent-session-orchestrator` / `ezagent-socialware`)。

### 6.B CLAUDE.md 一句 always-loaded 硬指针

在 `CLAUDE.md` 顶部(必读区)加一句 load-bearing:

> 任何 ezagent 代码改动,进 brainstorm 前先 load `ezagent-rule-gate` 走层级闸门(先定 E2E → 由轻到重选最轻可行层)。

CLAUDE.md 每个 prompt 都加载 ⇒ 确定性发现入口。

### 6.C PreToolUse chokepoint hook(安静兜底 + 纠偏)

原则:**规范不指望纪律,指望结构;把硬 gate 钉在"写代码"这个不可逆边界,而不是每一步;默认安静、关键时刻挡一下、从不挡死。**

- **触发**:`PreToolUse` 匹配 `Edit|Write`,且 `tool_input.file_path` 落在 `apps/**/*.ex`。
- **行为**:本 session **首次**触碰代码时,注入一句"这次改动过层级闸门了吗?判定落在哪层?";之后静默(session 级幂等,用 sentinel 文件)。对提问 / 文档 / 探索 **零打扰**。
- **加料(纠偏)**:命中 `apps/ezagent_core/` 或 `apps/ezagent_domain_*/` 时提示更尖锐——"你正要写**最重的层**,闸门 sanction 过吗?"。把"实时纠偏"做成确定性、低噪音、精准命中犯案现场的触发。
- **力度**:**提醒 / 追问,不硬 block**(硬 block 会让人绕路,绕路比漏报更糟)。真正硬 block 留给已存在的 `check_invariants` / CI(提交期)。
- **先例**:复用 `scripts/hooks/sub-step-gate.sh`(已是 PreToolUse 钩在 Bash/git commit)的同款手法,只是挪到"改 .ex 的那一刻"。新脚本如 `scripts/hooks/layer-gate-reminder.sh`,在 `.claude/settings.json` 注册。

---

## 7. 三阶段不重叠的治理链(闸门与现有 gate 的分工)

```
决策期     ezagent-rule-gate    →  「选对层」(本设计,process 闸门)
层内实施   ezagent-developer    →  「层内怎么写对」(规则库,按需查)
提交期     check_invariants/CI  →  「没写错 / 没违规」(强制 gate,已存在)
```

三段各管一段、互不重复。闸门**还会顺手**告诉你:选定该层后适用哪些不变式 / CI gate(链到 `architecture-invariants.md`),把决策期与提交期接上。

---

## 8. 数据流(一次改动怎么走)

```
brainstorm 一个 ezagent 改动
  → load ezagent-rule-gate
  → Step0 定 E2E 验收
  → Step1 阶梯(论证优先;看着可行就真跑运行时实验,E2E 过才打住)
  → 选出最轻可行层(若原指令更重 → 当场纠偏)
  → 交给 ezagent-developer 拿层内规则 / recipe 实施
  →(写代码时 chokepoint hook 在改 .ex 那一刻做确定性兜底)
  → Step2 友好中文解释收尾
```

---

## 9. 两个面向人的输出

### 9.1 实时纠偏(动手前)
开发者一上来就说"帮我在 core 里加…"时,闸门在动手前拦住,走阶梯,若发现更轻层可行 → 把方向掰回最轻可行层,并说明理由。chokepoint hook 在"要写 core/domain"那一刻提供确定性的第二道纠偏。

### 9.2 架构视角解释(收尾,中文友好)
`references/explain-template.md` 固定结构,至少包含:
1. **需求**:一句话复述。
2. **E2E 验收**:用什么 flow 证明成了。
3. **落在哪层 + 为什么**:从整体架构视角解释(为什么不更轻 / 为什么不必更重),引用决策树对应分支。
4. **挡下了什么**:哪些更重的层 / 哪些错误指令被拦,为什么。
5. **该层适用的 gate**:提交前会被哪些不变式 / CI 检查(链 `architecture-invariants.md`)。

目的:让开发者不只知道"AI 做了什么",还从整体架构理解"为什么这么做"。

---

## 10. 关键决策记录(已与用户拍板)

| # | 决策 | 取舍 |
|---|---|---|
| D1 | 载体走**方案 B**:薄路由 skill + 厚规则库 `ezagent-developer` | 精准命中"统一入口 / 前置路由闸门 / 规则唯一源",轻量先行 |
| D2 | 诊断修正获认可:规则非"散落无家",真痛点是**缺最轻两层决策路由 + 顶层指针过时** | 后续设计围绕补这两块 |
| D3 | 闸门挂在 **brainstorm 时机**(复用全公司都用的 superpowers brainstorm 习惯);**不改 vendored brainstorming 本体**(v6.0.3,改了会被覆盖) | 借力高频 skill 提升发现率,不 fork 上游 |
| D4 | 触发机制 = **薄 skill + 硬 hook 双保险** | 防 AI 漏触发(用户根虑) |
| D5 | 硬 hook 具体形态 = **PreToolUse chokepoint hook**(改 .ex 那一刻、session 级幂等、提醒不 block),**替换**掉早期"settings 关键词 hook(噪音) vs 纯 CLAUDE.md 指令(靠自觉)"的二选一 | 默认安静、关键时刻挡一下、从不挡死;放在不可逆边界 |
| D6 | 实验力度 = **混合(论证优先,可行则真跑)** | 平衡严谨与成本 |

---

## 11. 范围:v1 做什么 / 延后什么

**v1(本次)**:
- 新建 `ezagent-rule-gate` skill(`SKILL.md` + `layer-decision.md` + `runtime-capability-map.md` + `explain-template.md`)。
- `CLAUDE.md` 加 §6.B 那一句 always-loaded 硬指针。
- 新增 `scripts/hooks/layer-gate-reminder.sh` 并在 `.claude/settings.json` 注册(§6.C)。
- **最小**清理 §3 根因 3 里会主动误导闸门的过时指针:`CLAUDE.md` 的 `Behavior`→`Lifecycle`、`new-contract`→`lifecycle`、"8条"→P1-P27 表述;`README.md` 的 Phase 状态。

**延后(不在 v1)**:
- 旧文件全量瘦身 / 被替代(README / CONTRIBUTING / ROADMAP 的整体重构)。
- 数据驱动 registry(方案 C:规则结构化成机器可读单一源 + CI 校验规则与代码一致)——作为本设计成熟后的演进。
- `ezagent-developer` 内部中央索引(CI-gates registry):可作为 `runtime-capability-map` 之后的下一块。

**明确不做**:改 `ARCHITECTURE.md`(Allen 维护);发明新架构 Decision(走 Allen review)。

---

## 12. 可复用性

阶梯 + 运行时能力表是**架构稳定**的,不绑具体 phase;未来迭代只需扩 `layer-decision.md` 的走查样例、更新 `runtime-capability-map.md`。决策树与 phase 解耦 ⇒ 满足"持续复用"。

---

## 13. 验收(这套机制本身怎么算"做成了")

- **发现率**:对一个全新 ezagent 改动需求,AI 在动手前确定性地进入闸门(CLAUDE.md 指令 + chokepoint hook 双保险至少一条触发)。
- **路由正确**:对 §3 错误①/② 的代表性需求各 ≥1 个走查样例,闸门能判出正确的最轻层。
- **运行时盲区补齐**:`runtime-capability-map.md` 覆盖 orchestrator 工具能改的全部运行时项,可被引用判定"该不该做成 plugin"。
- **解释完整**:收尾输出按 §9.2 模板,新人能读懂"为什么落这层"。
- **安静**:hook 对纯文档 / 提问 / 探索零打扰;同一 session 不重复打扰。
- **不挡死**:有意识地改 core 仍可越过(确认即过),硬拦留给提交期 gate。

---

## 附录 A:分层实况表(决策树要锚定的事实地基)

| 层 | 代码体现 | 改它代价/门槛 | 典型该用它的需求 |
|---|---|---|---|
| **config** | `config/*.exs` + env + mix deps 清单 | 0–2h,重启(可选) | 端口/DB/SMTP、plugin 启停、默认 orchestrator |
| **session/运行时** | `apps/ezagent_domain_session/lib/ezagent/orchestrator/tools/` + `OrchestratorAdmin` Behavior | 几分钟、零代码,MCP 工具调用,持久到 DB | 加会话成员、改路由规则(RuleStore)、改 Legend、改 SessionTemplate 配置 |
| **plugin**(现有 13 个) | `apps/ezagent_plugin_*/`(OTP app) | 0.5–3h,重编译 | 新 agent 风味、新外部集成、UI、Template Class |
| **domain**(11 个) | `apps/ezagent_domain_*/` | 1–8h,重编译 + 可能 migration | 新 Kind 类型、某 Kind 首个核心 Behavior |
| **core**(~920 LOC) | `apps/ezagent_core/` | 4–40h,牵动全局 + 全部不变式,通常仅 Allen | 新 Registry、dispatch 模型、新 URI scheme、Capability 算法 |

## 附录 B:v1 要清理的过时指针清单

| 文件 | 过时内容 | 改成 |
|---|---|---|
| `CLAUDE.md` | 教 `use Ezagent.Behavior` 作开发者表面 | 开发者用 `use Ezagent.Lifecycle`;`use Ezagent.Behavior` 为 INTERNAL ENGINE |
| `CLAUDE.md` | 指 `references/new-contract.md` | 指 `references/lifecycle.md`(new-contract 为 engine 内部) |
| `CLAUDE.md` / `IMPLEMENTATION_ROADMAP.md` | "8 条硬不变式" | P1-P27 + `architecture-invariants.md` 20 条 |
| `README.md` | "Phase 0 complete" | 当前 phase7(或指向 roadmap 动态状态) |
