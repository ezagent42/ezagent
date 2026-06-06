# Soul / Skill / KB 全景设计

**Status:** r1 — 合并 SPEC r14 + 实施 gap 分析 + 初始化流程
**Branch:** `autoservice-dev`
**参考:** `docs/superpowers/specs/2026-06-04-soul-skill-kb-design.md` (详细 SPEC)
**AutoService 同架构实现:** `D:\Work\h2os.cloud\AutoService-dev-a\docs\superpowers\specs\2026-06-05-soul-reference-kb-design.md`

---

## §1 — 核心模型：三层 + 槽位

```
                加载方式              大小          有 {{slot}}?
                ────────              ────          ──────────
Soul            始终在 prompt 中       ~15KB 预算    ✅
(inline)        渲染进 CLAUDE.md                    {{key}} 占位符

Skill           磁盘文件               无限制         ✅ 可以 (Phase 2)
(on-disk)       Read 工具按需加载                    MVP 直接 copy
                索引注入 Soul

KB              MCP tool 查询          无限制         ❌
(queryable)     不占 prompt                         结构化数据 + 可信策略配置
                                                    system only
```

### 为什么是三层

旧 AutoService 四层 (soul/skill/flow_chunk/KB) 中 `skill` vs `flow_directive` 加载方式完全相同（磁盘文件 + Read on demand），合并为 Skill。旧 soul 76KB 不是必须 — 解剖后真正 inline 的只有 ~15KB:

```
旧 soul 76KB → 新架构:
  Soul inline:   ~15KB (身份/安全/分类 + {{slot}} key 引用 + Skill 索引)
  Skill on-disk: ~12KB (详细流程, Read on demand)
  KB queryable:  ~80KB (产品术语, MCP query, 不占 prompt)
```

### 分离判据

| 判据 | Soul (inline) | Skill (on-disk) | KB (queryable) |
|------|:--:|:--:|:--:|
| Agent 每次回复都需要？ | ✅ | ❌ (按场景 Read) | ❌ (按查询) |
| 影响 agent 身份/安全？ | ✅ | ❌ | ❌ |
| 体积 >2KB？ | ❌ → Skill | ✅ | ✅ |
| 需要结构化搜索？ | ❌ | ❌ | ✅ |
| 因租户不同而变化？ | → `{{slot}}` | → 分析决定 | ❌ |
| 是 smoke contract？ | ✅ (必须 inline) | ❌ | — |

### Ezagent 中的表达

```
三层           Ezagent 表达                          编辑方式
────           ────────────                          ────────
Soul           AgentTemplate.soul_slot_values        LV → template.read/write
  .md 模板      (flavor extra — 扩展现有 schema)

Skill          priv/ 下 .md 文件                     直接文件编辑
  .md 文件      可选 {{slot}} (Phase 2)

KB             kb.db + MCP script                    KBCurator Agent
               不进 Slice                             改文件 → 重建 kb.db
```

**domain/core 零变更** — 全部复用已有机制（AgentTemplate + Behavior.Template + Template Class）。

---

## §2 — 完整生命周期

### 2.1 初始化 (4 个入口)

```
入口 A: mix ezagent.demo.seed_autoservice
  条件: 有 vendored 数据 (cinnox 专属)
  流程: 解析旧 yaml → 提取默认值 → template.write
  状态: ✅ 已实现

入口 B: mix ezagent.skill.bootstrap <domain> <description>
  条件: 新领域, 有概念描述
  流程: 骨架模板 + Authoring Agent 分析 → 一键创建
  状态: ❌ 待实施

入口 C: LV "从 Bot Type 创建"
  条件: admin 登录, system workspace 有可用模板
  流程: 选择 Bot Type → fork → Onboarding Agent 引导填 key slot
  状态: ❌ 待实施

入口 D: LV "从零创建新 Bot Type"
  条件: 无合适模板, 纯冷启动
  流程: 骨架模板 → Agent 分析领域描述 → 生成草稿 → human review
  状态: ❌ 待实施
```

### 2.2 入口 B 详细流程: CLI bootstrap

```
mix ezagent.skill.bootstrap my-ecommerce \
  "电商客服, 售前(商品/价格/库存)+售后(退换货/物流), 无法解决→转人工"

Step 1: fork 骨架模板
  template://agent/system/skeleton → template://agent/<ws>/my-ecommerce

Step 2: Authoring Agent 分析领域描述
  → 建议 soul section 划分
  → 识别 {{slot}} 候选
  → 生成默认值
  → 生成初始 Skill 文件 (空或从 FAQ/文档生成)
  → 生成初始 KB 条目 (0 条, 需要提供产品文档 URL 或术语表)

Step 3: human review → confirm → dispatch template.write
Step 4: agent re-spawn → bot 就绪
```

### 2.3 入口 C/D 详细流程: LV 创建

```
LV → 展示 "可用 Bot Type" (从 system workspace AgentTemplate 列表):

  ┌──────────────────────────────────────┐
  │ 选择 Bot Type:                       │
  │ ○ 客服机器人 (CINNOX 验证)           │
  │ ○ 内部助手 (骨架)                    │
  │ ○ 从零创建新类型                      │
  └──────────────────────────────────────┘

选已有类型 (入口 C):
  1. fork system template → workspace
  2. Onboarding Agent 接管:
     "您好！我看到您创建了一个客服机器人。让我帮您完成初始配置。"
     逐个问关键 slot: bot name → escalation phrase → contact URL
     跳过有合理默认值的 slot
  3. confirm → template.write → spawn agent

从零创建 (入口 D):
  1. 输入: 领域描述 + 可选产品文档 URL
  2. Authoring Agent 分析 → 建议 section + slot → 生成草稿
  3. human review → 迭代 → confirm → template.write → spawn
```

### 2.4 决策权: 谁决定什么

```
                    人类决定                  AI 建议
                    ────────                  ──────
Soul section 划分    ✅ 最终决定              基于领域描述建议
哪些变 slot          ✅ 最终决定              分析可变性
slot 默认值          Review + 确认             从文档/描述提取
Skill 内容           ✅ 审核草稿               从 FAQ/文档生成
KB 条目              ✅ 审核                   从术语表/产品文档生成
模板更新             ✅ 决定时机+传播范围       检测信号 + 执行传播
```

### 2.5 编辑

```
Tenant 侧 (填槽位值):
  LV 表单 (解析模板 {{key}} → text inputs)
    → 修改 soul_slot_values
    → template.write
    → agent re-spawn

System 侧 (改模板结构):
  Chat → Authoring Agent
    → 修改模板文件 (.md)
    → 更新默认 slot_values
    → diff preview → confirm
    → template.write
```

### 2.6 渲染

```
Template Class instantiate:
  1. 读取 Soul 模板文件 (含 {{key}})
  2. render_slots(body, soul_slot_values) → 替换 {{key}}
  3. 扫描 Skill 目录 → 生成 Skill Index
  4. CLAUDE.md = rendered_soul + skill_index
  5. copy Skill 文件到 agent workdir
  6. 配置 KB MCP server (.mcp.json)
```

### 2.7 传播

```
System 更新模板文件:
  → 新 fork 的 tenant → 新模板
  → 已有 tenant → agent re-spawn 后生效
  → LV 提示 "模板有更新: +2 新 slot"
  → admin 手动 review + merge
```

---

## §3 — 可视化编辑设计

### 3.1 Tenant 侧: Slot 编辑

```
┌──────────────────────────────────────────────────────────────┐
│ 编辑 Bot: 客服机器人 (workspace://cinnox)        [保存] [重部署]│
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  Soul 配置                                                    │
│  ┌──────────────────────────────────────────────────────┐    │
│  │ identity                                              │    │
│  │   bot_full_name        [CINNOX AI Bot           ] ✏️  │    │
│  │   host_site_descriptor [CINNOX/M800             ] ✏️  │    │
│  │   self_intro_zh        [您好, 我是 CINNOX 的...  ] ✏️  │    │
│  │                                                        │    │
│  │ gate                                                   │    │
│  │   escalation_phrase    [这个具体数字我得帮您核实..] ✏️  │    │
│  │   weak_max_turns       [2                       ] ✏️  │    │
│  │                                                        │    │
│  │ classification                                         │    │
│  │   brand_short_name     [CINNOX                  ] ✏️  │    │
│  │   signals_new_strong   [explicit new-identity... ] ✏️  │    │
│  │   ...                                                  │    │
│  └──────────────────────────────────────────────────────┘    │
│                                                              │
│  Skill 列表                                                  │
│  ┌──────────────────────────────────────────────────────┐    │
│  │ general-inquiry-flow.md        [查看] [编辑]         │    │
│  │ bug-routing-flow.md            [查看] [编辑]         │    │
│  │ partner-handoff.md             [查看] [编辑]         │    │
│  └──────────────────────────────────────────────────────┘    │
│                                                              │
│  KB 管理                                                     │
│  ┌──────────────────────────────────────────────────────┐    │
│  │ escalation_keywords.json       [查看] [编辑]         │    │
│  │ glossary (350 条目)            [搜索] [添加]         │    │
│  └──────────────────────────────────────────────────────┘    │
└──────────────────────────────────────────────────────────────┘
```

**数据流**: 
- Slot 表单: 解析模板文件 `{{key}}` → text inputs → 修改 soul_slot_values → `template.write`
- Skill 列表: 扫描 skills 目录 → 展示 → 文件编辑
- KB: 读 kb.db / escalation_keywords.json → 展示 → KBCurator Agent 编辑

### 3.2 System 侧: 模板编辑 + AI 辅助

```
┌──────────────────────────────────────────────────────────────┐
│ 模板编辑器 (System Admin)                                     │
├────────────────────────────┬─────────────────────────────────┤
│                            │                                 │
│  Chat Panel                │  模板预览                       │
│  (与 Authoring Agent 对话) │  ┌─────────────────────────┐   │
│                            │  │ # {{identity.bot_full_   │   │
│  ┌──────────────────────┐  │  │    name}}                │   │
│  │ System Admin:        │  │  │                          │   │
│  │ 加一个 gate.max_retry│  │  │ 你是 {{identity.bot_full │   │
│  │ 槽位, 默认值 2       │  │  │   _name}}, ...           │   │
│  │                      │  │  │                          │   │
│  │ Authoring Agent:     │  │  │ ---                      │   │
│  │ 分析完成。建议在 gate│  │  │ ## Skill Index           │   │
│  │ section 新增 {{gate. │  │  │ - 产品咨询 → ...         │   │
│  │ max_retry}}, 类型    │  │  │ - Bug 上报 → ...         │   │
│  │ integer, 默认 2。    │  │  └─────────────────────────┘   │
│  │                      │  │                                 │
│  │ diff preview:        │  │  渲染预览                        │
│  │ + {{gate.max_retry}} │  │  ┌─────────────────────────┐   │
│  │ + slot_schema 加定义 │  │  │ 你好, 我是 CINNOX AI    │   │
│  │                      │  │  │ Bot, ...                 │   │
│  │ 确认创建?            │  │  └─────────────────────────┘   │
│  │                      │  │                                 │
│  │ System Admin: 确认   │  │                                 │
│  └──────────────────────┘  │                                 │
│                            │                                 │
└────────────────────────────┴─────────────────────────────────┘
```

**Agent 工具** (MCP 薄适配, 均 dispatch 已有 action):
- `template.read(uri)` → dispatch
- `template.write(uri, content)` → dispatch
- `file.read(path)` → bash/read
- `file.write(path, content)` → bash/write
- `skill.list(workspace)` → 扫描目录
- `kb.search(query)` → dispatch 或 MCP

### 3.3 冷启动向导

```
┌──────────────────────────────────────────────────────────────┐
│ 创建新 Bot                                                    │
├──────────────────────────────────────────────────────────────┤
│                                                              │
│  [1] 选择创建方式                                             │
│      ○ 从 Bot Type 创建 (推荐)                                │
│      ○ 从零创建 (需要提供领域描述)                             │
│                                                              │
│  [2] 如果选 Bot Type:                                        │
│      ┌────────────────────────────────────────┐              │
│      │ ○ 客服机器人  — 身份+分类+升级+EScalation│              │
│      │ ○ 内部助手    — 文档问答+工单+知识库    │              │
│      │ ○ 聊天分析    — 意图提取+情感+报告       │              │
│      └────────────────────────────────────────┘              │
│                                                              │
│  [3] Onboarding (AI 引导):                                    │
│      "您好! 我看到您创建了一个客服机器人。                    │
│       让我帮您完成初始配置。"                                  │
│                                                              │
│      Q1: 您的品牌叫什么?                                      │
│      A1: [_______________]                                    │
│                                                              │
│      Q2: 遇到机器人无法解决的问题时, 应该怎么回复?            │
│      A2: [马上为您转接人工客服_________]                      │
│                                                              │
│      Q3: 您的产品/服务的主要领域? (可选)                      │
│      A3: [_______________]                                    │
│                                                              │
│      跳过 → 使用默认值                                        │
│                                                              │
│  [4] [创建] → fork template → template.write → spawn agent   │
└──────────────────────────────────────────────────────────────┘
```

---

## §4 — 完整的 Agent 应用链路

### 4.1 从初始化到上线

```
┌─────────────────────────────────────────────────────────────────────┐
│ 1. 初始化 (入口 A/B/C/D)                                              │
│  ┌──────────┐    ┌──────────┐    ┌──────────┐    ┌──────────┐       │
│  │ seed     │    │ bootstrap│    │ LV       │    │ LV       │       │
│  │ cinnox   │    │ CLI      │    │ Bot Type │    │ 从零创建 │       │
│  │ (已实现) │    │ (待实施) │    │ (待实施) │    │ (待实施) │       │
│  └────┬─────┘    └────┬─────┘    └────┬─────┘    └────┬─────┘       │
│       └───────────────┴──────────────┴───────────────┘              │
│                          │                                          │
│                          ▼                                          │
│ 2. 模板创建                                                          │
│  AgentTemplate (system ws) ← template.write                        │
│    soul_slot_values: %{"identity.name" => "默认值", ...}           │
│                                                                     │
│ 3. Tenant fork                                                       │
│  AgentTemplate (tenant ws) ← Behavior.Template :fork (已有)         │
│    parent_template_uri: system/...                                  │
│    soul_slot_values: 继承默认值                                      │
│                                                                     │
│ 4. Tenant 编辑 (slot 填值)                                          │
│  LV → template.read → 改 soul_slot_values → template.write         │
│                                                                     │
│ 5. Agent 渲染 + spawn                                               │
│  Template Class instantiate:                                         │
│    File.read(soul_template) + render_slots + skill_index            │
│    → CLAUDE.md                                                      │
│    → skills/ (copy)                                                 │
│    → .mcp.json (KB MCP server)                                     │
│    → spawn cc/curl agent process                                    │
│                                                                     │
│ 6. System 更新模板 (迭代)                                            │
│  Authoring Agent → 修改 priv/ 模板文件 → 更新默认 slot_values       │
│  → tenant LV 提示更新 → admin review → re-spawn                    │
└─────────────────────────────────────────────────────────────────────┘
```

### 4.2 三个 Agent 的角色

```
┌─────────────────────────────────────────────────────────────────┐
│ Agent                    场景                 工具              │
│ ─────                     ────                 ────              │
│ Authoring Agent           创建/修改模板结构    file r/w          │
│   (cc, system ws)         决定 section/slot    template.read     │
│                           分析领域描述          template.write    │
│                                                验证一致性        │
│                                                                    │
│ Onboarding Agent          引导 tenant 填 slot  template.read     │
│   (cc, system ws)         逐个问关键 slot      template.write    │
│                           跳过有默认值的                          │
│                                                                    │
│ KBCurator Agent           管理 KB 条目          kb.search        │
│   (cc, system ws)         编辑 glossary         file r/w         │
│                           管理 escalation keys 重建 kb.db        │
└─────────────────────────────────────────────────────────────────┘
```

---

## §5 — 骨架模板

### 5.1 文件结构

```
apps/ezagent_plugin_autoservice/priv/skeleton/
  soul/
    soul.md              ← 6 个通用 section, 全部标 {{slot}}
  skills/
    .gitkeep             ← 空 (试运行后生成)
  kb/
    escalation_keywords.json  ← 空数组 (从试运行中积累)
```

### 5.2 Soul 骨架内容

```markdown
# {{identity.bot_full_name}}

你是 **{{identity.bot_full_name}}**，嵌入在 {{identity.host_site_descriptor}} 网站。

## 身份
- 你叫 {{identity.bot_full_name}}
- 你的自我介绍 (中文): {{identity.self_intro_zh}}
- 你的自我介绍 (英文): {{identity.self_intro_en}}

## 服务范围
你负责回答以下领域的问题: {{purpose.topics_covered}}

## 分类规则
根据客户消息判断意图:
- 新客户信号: {{classification.signals_new_strong}}
- 现有客户信号: {{classification.signals_existing_strong}}
- 无法确定时: {{classification.unknown_type_clarifier_zh}}

## 升级策略
遇到以下情况立即升级给人工:
- 关键词: {{gate.escalation_triggers}}
- 升级措辞: {{gate.escalation_phrase}}
- 最多追问次数: {{gate.max_clarify_turns}}

## 对话风格
- 每次回复最多 {{conversation.max_sentences}} 句
- 禁止使用以下开头: {{conversation.banned_openings}}
- 正面案例: {{conversation.good_examples}}

## 隐私与安全
- 以下操作需要额外验证: {{privacy.sensitive_operations}}

## Skill Index
(agent spawn 时由 Template Class 扫描 skills/ 目录自动生成)
```

---

## §6 — 实施序列

### 已实施 (Phase 1)

| # | 内容 | 状态 |
|---|------|------|
| 1 | `cc_agent.ex` / `curl_agent.ex`: `template_data_extra/1` + `soul_slot_values` | ✅ |
| 2 | `cinnox_assets.ex`: `render_slots/2`, `build_cc_claude_md_with_slots/1`, `default_soul_slot_values/0` | ✅ |
| 3 | `customer_session.ex`: `provision/2` soul_slot_values + rendered CLAUDE.md | ✅ |
| 4 | SPEC + README + Excalidraw 图 | ✅ |

### Phase 2 — Tenant 编辑 + Skill 索引 (待实施)

| # | 内容 | 估算 LOC | Tier |
|---|------|---------|------|
| 1 | LV Slot 编辑面板: 解析模板 `{{key}}` → text input → `template.write` | ~150 | LV |
| 2 | Template Class: 扫描 skills 目录 → 生成 Skill Index → 注入 CLAUDE.md | ~40 | plugin cc |
| | | **~190** | |

### Phase 3 — 初始化入口 (待实施)

| # | 内容 | 估算 LOC | Tier |
|---|------|---------|------|
| 1 | 骨架模板文件: `priv/skeleton/soul/soul.md` | ~30 | plugin autoservice |
| 2 | `mix ezagent.skill.bootstrap` CLI task | ~60 | plugin autoservice |
| 3 | Authoring Agent seed (cc agent, system ws) | ~80 | plugin autoservice |
| 4 | Authoring MCP tools (file r/w + template.read/write 薄适配) | ~60 | plugin autoservice |
| 5 | Onboarding Agent seed (cc agent, system ws) | ~60 | plugin autoservice |
| 6 | LV: 创建新 Bot 面板 (Bot Type 选择 + Onboarding 引导) | ~100 | LV |
| | | **~390** | |

### Phase 4 — System 编辑 + 传播 (待实施)

| # | 内容 | 估算 LOC | Tier |
|---|------|---------|------|
| 1 | LV: 模板编辑 Chat Panel (与 Authoring Agent 对话) | ~80 | LV |
| 2 | LV: 模板预览 + diff 视图 | ~60 | LV |
| 3 | LV: 模板更新通知 + merge 视图 | ~100 | LV |
| 4 | KBCurator Agent seed | ~60 | plugin autoservice |
| | | **~300** | |

### 总计

| Phase | 内容 | LOC | 累计 |
|-------|------|-----|------|
| 1 | 核心渲染链路 | 已实施 | — |
| 2 | Tenant 编辑 + Skill 索引 | ~190 | ~190 |
| 3 | 初始化入口 | ~390 | ~580 |
| 4 | System 编辑 + 传播 | ~300 | ~880 |

全部 plugin/LV 层。domain/core 零变更。

---

## §7 — 不变式自查

- [ ] **P1**: core 零变更 ✅
- [ ] **P8**: 不建新 Kind/Behavior/Action/Scheme，全部复用已有机制 ✅
- [ ] **P3**: Soul SoT = `priv/` 文件 + AgentTemplate.soul_slot_values ✅
- [ ] **P14**: 编辑走 dispatch `template.read` / `template.write` ✅
- [ ] **P20**: 不引入新 scheme ✅
- [ ] **P26**: fork = config only (slot_values 复制) ✅
- [ ] **Authoring Agent 安全**: cap scope-bounded to workspace (P15) ✅
- [ ] **Skill 文件编辑**: Agent 直接文件操作 → 编辑历史由 git 追踪 ✅
