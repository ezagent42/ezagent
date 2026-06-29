# Ezagent Rule-Gate(层级升级闸门)设计

- **日期**:2026-06-29
- **版本**:v2(re-anchor 到已落地的两轴 taxonomy;v1 见 git 历史)
- **状态**:设计待 review(用户 review spec 后再出实施计划)
- **载体决策**:方案 B —— 两层拆分(薄「路由闸门 skill」+ 厚「规则库 skill `ezagent-developer`」)
- **目标仓**:ezagent42/ezagent(Elixir/Phoenix 平台仓)
- **base commit**:`755b2a9b`(= 设计期 `origin/main`)

---

## 1. 背景与真实痛点

症状:实施方向错误频发,本质是「在比需求更重的层去改动」。两类高频错误:
- **错误①**:本该加个 plugin 就满足的,最后改到了 core / domain。
- **错误②**:本该改 config、或用户在 session 里用 orchestrator 运行时就能完成(甚至只需 seed 一条数据)的,最后却做成了一个 plugin。

面向人群:**不熟整体架构、用 AI 改码的新开发者**——核心防"乱改 / 改错层";同时把"解释 + 纠偏"做完整。

> **v2 关键修正**:经只读测绘 + 深读 socialware/taxonomy 三件套后确认——仓里**已经有**分层定义,甚至有一张判定流程图;真痛点不是"没有规则",而是「**层定义有了但缺一个'给需求选最轻 effort'的可发现前门,且最轻的两个 rung(config/运行时)没被纳入**」。本设计据此 re-anchor(见 §3、§5)。

---

## 2. 测绘结论:治理来源现状(只读盘点)

### 2.1 五类来源(按职能,非文件位置)

| 类 | 来源 | 性质 |
|---|---|---|
| ① 真·权威源(规则定义处) | `.claude/skills/ezagent-developer/`:SKILL.md(导航)+ 12 references(~2146 行):`design-principles.md`(P1-P27,5 组)、`architecture-invariants.md`(20 条 + CI gate)、`capbac.md`/`lifecycle.md`/`new-contract.md`/`three-tier-structure.md`/`anti-patterns.md`/`how-to-recipes.md` 等 | **已高度集中** |
| ② 权威 rationale + 决策档案 | `ARCHITECTURE.md`(3359 行,Allen 维护、只读)+ `GLOSSARY.md`(Decision Log **#1–#155** + 术语表 + 消歧) | 教学论证 + 历史 |
| ②b **分层/载体 taxonomy(测绘首轮漏看)** | `docs/socialware-concepts.md`(**已落地**:base/socialware/fixture/recipe/responsibility 概念轴 + 5 步作者指南)、`docs/together/2026-06-28/specs/ezagent-taxonomy-boundaries.md`(**DESIGN**:4 carrier layers + **§3 判定流程图** + 6 red lines + §6 提案 arch-gate)、`docs/together/2026-06-26/specs/socialware-unification.md`(**DESIGN**,lead 拍板,P0–P10)、**GLOSSARY Decision #155** | 已是权威概念,但散/埋/部分 DESIGN |
| ③ 入口 / 启动 checklist / 指针 | `CLAUDE.md`(每 prompt 加载,纯指针)、`README.md`、`CONTRIBUTING.md`、`IMPLEMENTATION_ROADMAP.md`、`AGENTS.md`(纯 Phoenix,独立无重叠) | **过时最多** |
| ④ 强制 gate(真会跑) | `scripts/hooks/sub-step-gate.sh`(PreToolUse,commit/tag 前 `format+test+check_invariants`,exit 2 阻断)、CI `ci.yml`、`mix ezagent.{arch.scan,doc.scan,check_invariants,check_invariants.lifecycle}`(后者已有 NP-2 层词汇 lint)、`protect-dev-together-skill.yml` | 提交期强制 |
| ⑤ per-phase 规格 + how-to | `docs/phase-specs/`(phase0–7)、`docs/guide/`、`docs/onboarding/`、`docs/scenarios/` | 文档 |

### 2.2 已落地的两条正交轴(re-anchor 的地基)

- **轴 A — 代码依赖方向**:`core → domain → plugin`(`three-tier-structure.md`)。
- **轴 B — artifact carrier 层**:`L1 code / L2 definition-data / L3 runtime-state / L4 EZAGENT_HOME files`(taxonomy SPEC §0;Decision #155)。一个 plugin 可同时发 L1 code + L2 seed 数据。
- **概念轴**:`base / socialware / fixture / recipe / responsibility`(socialware-concepts)。

taxonomy SPEC **§3 已有一张判定流程图**「new thing goes in which layer?」(6 步 first-match-wins,落在轴 B);**§5 有 6 条 red lines**(核心:**业务语义只能进 L2 数据,永不进 L1 code / core**)。`three-tier-structure.md` 顶部已 link 出去这些。

---

## 3. 诊断:三个根因(v2 修正)

**根因 1(最致命)—— 有"落哪层"的判定,但缺"给需求选最轻 effort"的前门,且漏了最轻两个 rung。**
taxonomy §3 流程图回答的是「这个 **artifact** 物理落 L1/L2/L3/L4 哪层」——它假设你**已经决定要造什么 artifact**。它**不回答**:"给一个**需求**,能不能干脆**不写代码**(改 config / 运行时 seed 数据)就满足?"。具体:
- 它没有 **config / 运行时-orchestrator** 这两个最轻 rung(它是 artifact-storage 视角,不是 runtime-vs-build / 能否零代码视角)。
- 它没有 **E2E-first + 逐层证伪** 的纪律(选层是静态判断,不是"先证明更轻的走不通")。
- 这正是错误②的成因:`runtime-capability-map`(运行时不写代码能改什么)从未被映射;AI 看不到这条路,默认往 plugin 跳。

**根因 2 —— 入口分裂 + 不可发现。** AI 第一跳是 `CLAUDE.md`(纯指针);taxonomy §3 流程图 + 6 red lines + 5 步作者指南**埋在 `docs/together/` 的 dated SPEC、且部分是 DESIGN 状态**,不在每-prompt 可发现路径;`ezagent-developer/three-tier-structure.md` 只 link 出去、不前置成"决策前门"。

**根因 3 —— 顶层指针过时 / 自相矛盾。** 实锤:`CLAUDE.md` 教 `use Ezagent.Behavior`(应为 `use Ezagent.Lifecycle`,前者已是 INTERNAL ENGINE、Phase C gate 硬拒);指 `references/new-contract.md`(应指 `lifecycle.md`);"8 条硬不变式"(实为 P1-P27 + 20 条);`README.md` "Phase 0 complete"(现 phase7);且**完全没提 Decision #155 / carrier-layer taxonomy**。

---

## 4. 设计目标(对照用户六条)

1. AI 容易发现的「统一入口」。
2. 进入后有条理、够快地定位规则——尤其前置一个「决策/路由」闸门:拿到需求先判断「满足它的最轻的层/载体是哪」再动手。
3. 规则整合成唯一实时来源(skill 成权威导航,旧文件逐步瘦身;**只引不抄**已落地 taxonomy)。
4. 核心开发者(人)方便维护、修改。
5. 人性化:面向 AI,但收尾总结用对人友好的语言讲清「做了什么、为什么这么做(架构视角)、挡下了哪些违规」。
6. 未来 ezagent 再迭代可持续复用。

---

## 5. 核心模型:层级升级闸门(挂在 brainstorm 时机)

### 5.1 闸门三步

**Step 0 —— 先定 E2E 验收**:先问"什么 E2E flow 能证明它成了"。复用 `docs/phase-specs/*/VERIFICATION.md` / `e2e-parity/FLOWS.md` + dev-together 的 demonstrable-DoD。

**Step 1 —— 由轻到重升级阶梯,每档"被证伪"才准往上爬**(实验力度 = 混合:论证优先,可行则真跑;显然不可能则记一条书面理由即可升级)。

**Step 2 —— 两个面向人的输出**(§9):实时纠偏 + 架构视角解释。

### 5.2 直觉阶梯 = 既有两轴词汇(不另立第三套 taxonomy)

给新人一条**直觉教学梯**,但**每一档都用既有词汇定义**,并标"今天能否零代码":

| 闸门档(直觉名) | = 既有权威词汇 | 今天能否零代码 | 典型需求 |
|---|---|---|---|
| **L0 config / deploy** | env + mix deps 开关 | 改配置,(可选)重启 | 端口/DB/SMTP、plugin 启停、默认 orchestrator |
| **L1 运行时 orchestrator** | 写 **carrier-L2 定义数据(ConfigObject)** + **carrier-L3 slice**,经 orchestrator 工具 | **零代码、不重启**(取决于 socialware P3–P5 落地度,见 §7) | 加会话成员、改路由规则(RuleStore)、改 Legend、(target)seed 一个 socialware-def / recipe |
| **L2 build-time data seed** | carrier-L2 数据,随发布 seed 脚本 | 数据,但要 deploy | 预置 recipe / socialware 定义 |
| **L3 plugin** | **carrier-L1 code**,plugin tier(新 generic 机制 / 新 shape Behavior / adapter) | 写代码、重编译 | 新 agent 风味、新外部集成、新 shape |
| **L4 domain** | carrier-L1 code,domain tier(新 Kind / load-bearing 词汇) | 同上,更重 + 可能 migration | 新 Kind 类型 |
| **L5 core** | carrier-L1 code,core(primitives) | 几乎只有 Allen | 新 Registry、dispatch、URI scheme、Capability 算法 |

> **注意**:闸门档名(L0–L5)是 effort/升级序,**不等于** carrier-layer 编号(L1–L4)。文档里两者出现时显式区分:写「闸门档 Ln」或「carrier-L n」。

闸门的独有价值 = taxonomy §3 回答"artifact 落哪 carrier 层";闸门回答**正交的**"给**需求**选最轻 effort 档,且有没有用 E2E 证明更轻档走不通"。**红线引用**(永真,今天已验证 FIXED):业务语义→carrier-L2 数据,永不进 carrier-L1/core;加新 socialware 不得改 `ezagent_core`。

---

## 6. 组件构成(三件套:内容 / 在场 / 兜底)

```
ezagent-rule-gate skill      →  内容(决策树 + 运行时能力表 + 解释模板)
CLAUDE.md 一句 always-loaded  →  每个 prompt 都在场的 why/how 指针
PreToolUse chokepoint hook    →  改代码那一刻的确定性、安静的兜底 + 纠偏
```

### 6.A 新建薄 skill `ezagent-rule-gate`

- `SKILL.md`:触发 description = "**决定 ezagent 改动方向 / 选哪一层 / brainstorm 一个 ezagent 改动时**";正文 = §5 升级阶梯 + §9 两输出契约。**保持薄**,深内容下沉 references。
- `references/layer-decision.md`:**决策树**(§5.2 直觉阶梯,逐档 go/no-go 判定 + 10–20 个真实需求走查样例,覆盖错误①/②代表案例)。**只引不抄**:link 到 taxonomy §3 流程图、§5 6 red lines、socialware-concepts 5 步、Decision #155;**新增** = config/运行时两 rung + effort 升级序 + E2E-first 纪律 + **landed/target 标注**。
- `references/runtime-capability-map.md`:**最高价值新产物**——"orchestrator 运行时不写代码能改哪些 carrier-L2/L3 数据,且**当前 main 真的通了的部分**"。从 `apps/ezagent_domain_session/lib/ezagent/orchestrator/tools/*.ex`、`behavior/orchestrator_admin.ex`、`Ezagent.Routing.RuleStore`、socialware `DefinitionRegistry` / `RecipeRegistry` 提炼。**每行标 landed / target(P3–P5)**。直接解错误②盲区。
- `references/explain-template.md`:§9.2 收尾解释的中文模板。

命名遵循项目约定(kebab-case、`ezagent-` 前缀)。

### 6.B CLAUDE.md 一句 always-loaded 硬指针

`CLAUDE.md` 必读区加一句 load-bearing:

> 任何 ezagent 代码改动,进 brainstorm 前先 load `ezagent-rule-gate` 走层级闸门(先定 E2E → 由轻到重选最轻可行档;业务语义优先 carrier-L2 数据,别进 core)。

### 6.C PreToolUse chokepoint hook(安静兜底 + 纠偏)

原则:**规范不指望纪律,指望结构;硬 gate 钉在"写代码"这个不可逆边界;默认安静、关键时刻挡一下、从不挡死。**

- **触发**:`PreToolUse` 匹配 `Edit|Write`,且 `tool_input.file_path` 落在 `apps/**/*.ex`。
- **行为**:本 session **首次**触碰代码时,注入"这次改动过层级闸门了吗?判定落哪档?";之后静默(session 级幂等,sentinel 文件)。对提问 / 文档 / 探索**零打扰**。
- **加料(纠偏)**:命中 `apps/ezagent_core/` 或 `apps/ezagent_domain_*/` 时提示更尖锐——"你正要写最重的 carrier-L1/core,闸门 sanction 过吗?业务语义是不是其实该进 carrier-L2 数据?"。
- **力度**:**提醒 / 追问,不硬 block**(硬 block 会让人绕路)。硬 enforcement 留给已存在的 `check_invariants` / CI(提交期)。
- **先例**:复用 `scripts/hooks/sub-step-gate.sh`(已是 PreToolUse 钩 Bash)同款手法。新脚本如 `scripts/hooks/layer-gate-reminder.sh`,在 `.claude/settings.json` 注册。

---

## 7. landed vs target:闸门是活文档,不照抄静态 SPEC

socialware P0–P10 中,「**加 socialware = 纯 seed carrier-L2 数据、零代码**」是 **target**(靠 P3 de-hardcode behavior-set→`installs` 数据 / P4 socialware-def ConfigObject / P5 抽 config),而 **main 现在约 P0–P2**——**今天**加 socialware 仍部分要碰 call-site / 代码。

⟹ 闸门**必须区分"今天能走"和"目标路径"**:
- `layer-decision.md` 的 socialware 相关格 + `runtime-capability-map.md` 每行都带 **landed / target(phase)** 标注。
- 内容**以 link 权威源为主**(socialware-concepts / Decision #155 / taxonomy SPEC),自己只维护 **effort 升级脊梁 + 当前 landed 现状**,降低 staleness。
- 这两块是仅有的"会随 P3–P10 演进"的部分;其余组件与 socialware 进度无关。

---

## 8. 爆炸半径:未落地代码会不会硬 block 本设计?

**结论:不会硬 block。** 未落地的 P3–P10 / taxonomy(DESIGN)/ §6 arch-gate(提案),只碰到 7 个产物里的 2 个,且都是**加法**(让最轻路径更轻/更宽),不推翻决策树**结构**。

| 产物 | 依赖未落地? | 影响 |
|---|---|---|
| ① SKILL.md 流程 | 无 | 独立 |
| ② 决策树**脊梁** + red lines | 无 | red lines 今天已验证 FIXED(taxonomy §4.3/§4.6),脊梁稳定 |
| ② 决策树"加 socialware=零代码"**单格** | 软(target=P3–P5) | 标 landed/target,结构不变,落地后只刷该格值 |
| ③ `runtime-capability-map` | 软(P3–P5 扩可写集) | **增量友好**:按现状写+标注;落地后长新行不作废 |
| ④ explain-template / ⑤ CLAUDE.md 句 / ⑥ hook / ⑦ 过时清理 | 无 | 独立 |

**唯一真风险(非 block)= 词汇漂移**:P3–P5 若改 socialware-def 寻址 / `installs` 字段名,我们引用会 stale。**缓解内建**:只引不抄 + landed/target 标注 + 活文档。
**§6 arch-gate**:本设计**不揽**(lead 的事),其未落地与我们零关系。

---

## 9. 两个面向人的输出

### 9.1 实时纠偏(动手前)
开发者一上来说"帮我在 core 里加…"时,闸门动手前拦住,走阶梯,若更轻档可行 → 掰回最轻可行档并说明理由。chokepoint hook 在"要写 core/domain"那一刻提供确定性的第二道纠偏。

### 9.2 架构视角解释(收尾,中文友好)
`references/explain-template.md` 固定结构,至少含:
1. **需求**:一句话复述。
2. **E2E 验收**:用什么 flow 证明成了。
3. **落在哪档 + 为什么**:整体架构视角(为什么不更轻 / 不必更重),引决策树分支 + 相关 red line。
4. **挡下了什么**:哪些更重档 / 哪些错误指令被拦,为什么。
5. **该档适用的 gate**:提交前会被哪些不变式 / CI 检查(链 `architecture-invariants.md`)。

---

## 10. 三阶段不重叠的治理链

```
决策期     ezagent-rule-gate    →  「选对档」(本设计,process 闸门)
层内实施   ezagent-developer    →  「层内怎么写对」(规则库,按需查)
提交期     check_invariants/CI  →  「没写错 / 没违规」(强制 gate,已存在)
```

闸门还会顺手告诉你选定档适用的不变式 / CI gate,把决策期与提交期接上。

---

## 11. 数据流

```
brainstorm 一个 ezagent 改动
  → load ezagent-rule-gate
  → Step0 定 E2E 验收
  → Step1 阶梯(论证优先;看着可行就真跑运行时实验,E2E 过才打住;查 landed/target)
  → 选出最轻可行档(若原指令更重 → 当场纠偏)
  → 交给 ezagent-developer 拿层内规则 / recipe 实施
  →(写代码时 chokepoint hook 在改 .ex 那一刻确定性兜底)
  → Step2 友好中文解释收尾
```

---

## 12. 关键决策记录(已与用户拍板)

| # | 决策 | 取舍 |
|---|---|---|
| D1 | 载体走**方案 B**:薄路由 skill + 厚规则库 `ezagent-developer` | 命中"统一入口/前置路由/规则唯一源",轻量先行 |
| D2 | 诊断修正获认可 | 见 §3 |
| D3 | 闸门挂 **brainstorm 时机**;**不改 vendored brainstorming 本体**(v6.0.3) | 借力高频 skill,不 fork 上游 |
| D4 | 触发 = **薄 skill + 硬 hook 双保险** | 防 AI 漏触发 |
| D5 | 硬 hook = **PreToolUse chokepoint hook**(改 .ex 那刻、session 幂等、提醒不 block) | 默认安静、关键挡一下、从不挡死 |
| D6 | 实验力度 = **混合(论证优先,可行则真跑)** | 平衡严谨与成本 |
| **D7** | **re-anchor 到已落地两轴 taxonomy**(轴 A 三 tier + 轴 B carrier layers + 概念轴);直觉阶梯保留作前门但用既有词汇定义;**只引不抄** | 不另立第三套 taxonomy(避免制造新的重叠矛盾) |
| **D8** | 未落地 P3–P10 **不硬 block**;**大胆先写 spec+计划**,计划埋"实施前置检查门",并行等代码落地 | 见 §8 |
| **D9** | **不揽** taxonomy §6 提案 arch-gate(硬 enforcement) | lead 的事;我们只做发现+纠偏 nudge |

---

## 13. 范围:v1 做什么 / 延后什么

**v1**:
- 新建 `ezagent-rule-gate` skill(`SKILL.md` + `layer-decision.md` + `runtime-capability-map.md` + `explain-template.md`)。
- `CLAUDE.md` 加 §6.B 那句 always-loaded 指针 + Decision #155 / carrier-taxonomy 指针。
- 新增 `scripts/hooks/layer-gate-reminder.sh` 并在 `.claude/settings.json` 注册。
- **最小**清理 §3 根因 3 会主动误导的过时指针(`Behavior`→`Lifecycle`、`new-contract`→`lifecycle`、"8条"→P1-P27;`README` phase 状态)。

**实施前置检查门(写进计划)**:真正建 skill 前先 `git fetch` + 核对「P3–P5 落地了吗 / 当前 phase / 运行时可写集」,据此刷新 `layer-decision.md` 的 socialware 格 + `runtime-capability-map.md`。

**延后**:旧文件全量瘦身;数据驱动 registry(方案 C);`ezagent-developer` 内部中央 CI-gates registry。

**明确不做**:改 `ARCHITECTURE.md`;发明新架构 Decision;建 taxonomy §6 arch-gate(D9)。

---

## 14. 可复用性

effort 升级脊梁 + 两轴映射是**架构稳定**的;未来迭代只需扩 `layer-decision.md` 走查样例、刷新 `runtime-capability-map.md` 的 landed/target。与具体 phase 解耦 ⇒ 持续复用。

---

## 15. 验收(这套机制本身怎么算"做成了")

- **发现率**:对一个全新 ezagent 改动需求,AI 动手前确定性进入闸门(CLAUDE.md 指令 + chokepoint hook 至少一条触发)。
- **路由正确**:错误①/② 代表性需求各 ≥1 走查样例,闸门判出正确最轻档。
- **运行时盲区补齐**:`runtime-capability-map.md` 覆盖 orchestrator 运行时可写的 carrier-L2/L3 项,带 landed/target 标注。
- **不另立词汇**:决策树用既有两轴 + 概念轴词汇,red lines 来自引用而非复述。
- **解释完整**:收尾按 §9.2 模板,新人读懂"为什么落这档"。
- **安静 + 不挡死**:hook 对文档/提问零打扰、session 不重复;有意识改 core 确认即过。

---

## 附录 A:分层实况表(决策树锚定的事实地基)

见 §5.2。carrier-layer 定义见 taxonomy SPEC §0 / Decision #155;三 tier 见 `three-tier-structure.md`;概念轴见 `socialware-concepts.md`。

## 附录 B:v1 要清理的过时指针清单

| 文件 | 过时内容 | 改成 |
|---|---|---|
| `CLAUDE.md` | 教 `use Ezagent.Behavior` 作开发者表面 | 开发者用 `use Ezagent.Lifecycle`;`use Ezagent.Behavior` 为 INTERNAL ENGINE |
| `CLAUDE.md` | 指 `references/new-contract.md` | 指 `references/lifecycle.md` |
| `CLAUDE.md` / `IMPLEMENTATION_ROADMAP.md` | "8 条硬不变式" | P1-P27 + `architecture-invariants.md` 20 条 |
| `CLAUDE.md` | 无 carrier-layer / Decision #155 指针 | 加指向 `socialware-concepts.md` + Decision #155 + taxonomy SPEC |
| `README.md` | "Phase 0 complete" | 当前 phase7(或指向 roadmap 动态状态) |

## 附录 C:已读的权威源(本设计 link、不复述)

- `docs/socialware-concepts.md`(LANDED)— 概念轴 + 5 步作者指南 + anti-patterns
- `docs/together/2026-06-28/specs/ezagent-taxonomy-boundaries.md`(DESIGN)— §0 4 carrier layers / §3 判定流程图 / §5 6 red lines / §6 提案 arch-gate
- `docs/together/2026-06-26/specs/socialware-unification.md`(DESIGN,lead)— P0–P10
- `GLOSSARY.md` Decision #155 — carrier-layer taxonomy + anti-leak red lines
- `.claude/skills/ezagent-developer/references/three-tier-structure.md` — 轴 A + 顶部正交轴提示
