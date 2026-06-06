# SPEC — Soul / Skill / KB 设计（最小 domain 变更）

**Status:** r13 — 吸取 AutoService 实施经验: Soul lint gate、Skill discovery 机制、路径权限、Phase 0 实测数据
**Branch:** `autoservice-dev`
**参考:** AutoService `docs/superpowers/specs/2026-06-05-soul-reference-kb-design.md` (同架构实现版)

---

## §1 — 核心模型：模板 + 槽位

### 1.1 旧 AutoService 的真实模型

旧系统 `customer.yaml` 有 22 个 section，~100 个 key-value — 这是**模板 + 槽位**模型，不是自由编辑 markdown。

### 1.2 槽位模型的优势

| | 自由编辑 markdown | 槽位填充 |
|---|---|---|
| **租户改什么** | 整个文本 | 只改槽位值 |
| **会不会破坏结构** | 容易 | **不会** — 结构由系统锁定 |
| **模板更新传播** | 三路文本 diff3 | **确定性**：新模板 + 旧槽位值 |
| **AI Editor Agent** | 需理解全文语义 | **只辅助填值** |

### 1.3 三层分离：基于加载方式

旧 AutoService 的 soul 膨胀到 76KB（30KB soul + 46KB flow chunks），不是内容必须这么大，而是**迭代开发中什么都往 soul 塞，没有分离机制**。解剖旧 soul 的实际构成:

```
旧 soul 总内容 ~76KB:
  身份/品牌描述            ~2KB   (inline)
  行为规则/禁止模式         ~5KB   (inline, 安全约束)
  分类逻辑 (gate)           ~3KB   (inline, 一级路由)
  升级策略                  ~1KB   (inline)
  对话风格                  ~2KB   (inline)
  
  详细流程步骤 (lead/new/bug) ~10KB  → 提取到 Skill (Read on demand)
  tenant 可变文本             ~5KB  → {{slot}} 替代后只剩 ~0.5KB key 引用
  示例/案例                   ~2KB  → 提取到 Skill
  
  产品术语/价格/规格         ~80KB  → KB glossary (queryable, 不占 prompt)

→ 真正必须在 prompt 中的: ~13.5KB
```

**有了 slot 模型 + KB + Skill 分离后，soul 目标预算 ~15KB（迁移场景可达，冷启动需配合提取 gate）。三层足够:**

旧系统的四层（soul/skill/flow_chunk/KB）中，`skill` vs `flow_directive` 标签是历史产物，两者加载方式完全相同（磁盘文件 + Read on demand），合并为 Skill。

```
                加载方式              大小         有 slot?      
                ────────              ────         ───────      
Soul           始终在 prompt 中       ~15KB 预算   ✅ {{key}}
(inline)       渲染进 CLAUDE.md                    

Skill          磁盘文件               无限制        ✅ 可以 (Phase 2)
(on-disk)      Read 工具按需加载                   MVP: 直接 copy, 不渲染 slot

KB             MCP tool 查询          无限制        ❌
(queryable)    不占 prompt                         结构化数据 + 可信策略配置
                                                   (如 escalation_keywords), system only
```

**旧系统的分离需要重新审视** — 不要因为旧系统把某个值放在 `customer.yaml` 就认定它是 slot，也不要因为旧系统把某段文本放在 skill 里就认定它不该有 slot。Template Authoring Agent 重新分析，从第一性原则出发。

### 1.4 分离判据：什么进 Soul、什么进 Skill、什么进 KB

| 判据 | Soul (inline) | Skill (on-disk) | KB (queryable) |
|------|:--:|:--:|:--:|
| **Agent 每次回复都需要？** | ✅ | ❌ (按场景 Read) | ❌ (按查询 MCP) |
| **影响 agent 身份/安全？** | ✅ (banned patterns, 身份) | ❌ | ❌ |
| **体积大 (>2KB)？** | ❌ (提取到 Skill) | ✅ | ✅ |
| **需要结构化查询？** | ❌ | ❌ | ✅ (术语搜索) |
| **因租户不同而变化？** | → `{{slot}}` | → 分析决定是否 `{{slot}}` | ❌ (system only) |
| **是 smoke contract？** | ✅ (必须 inline) | ❌ (但不能依赖 Read 成功) | — |

### 1.5 谁来判断分离、怎么执行

**分离是模板创作阶段的设计决策，由 Template Authoring Agent 辅助人类执行。不是运行时行为。**

#### 迁移路径（有旧数据）

```
输入: 旧 customer_soul.md + customer.yaml + skills/ + flow_chunks/
  │
  ▼
Template Authoring Agent 分析流程:
  │
  ├── Step 1: 识别 {{slot}} 候选
  │   对于 customer.yaml 中的每个 key-value:
  │     - 分析 soul .md 中对应位置 → 该值是单一租户的还是跨租户可变的？
  │     - 分析 skills/flow_chunks 中是否有重复硬编码 → 消除重复
  │   输出: "建议 47 个 key 标记为 {{slot}}，18 个锁定为 body（跨租户一致），
  │          35 个进一步分析（数据不足）"
  │
  ├── Step 2: 识别 Skill 提取候选
  │   对于 soul 中 >2KB 的连续段落:
  │     - 是否每次对话都需要？→ 如果是，保持 inline
  │     - 是否只在特定场景需要？→ 建议提取到 Skill 文件
  │   对于 skills/flow_chunks 中有重复参数的:
  │     - "retry=2" 出现在 3 个地方 → 建议 1 个 {{slot}}，3 个文件引用它
  │   输出: "建议提取 5 个 section 到 Skill 文件，
  │          合并 skills 和 flow_chunks 中的重复参数为 12 个共享 {{slot}}"
  │
  ├── Step 3: 识别 KB 候选
  │   对于纯事实性内容（术语定义、价格表、规格）:
  │     - 是否需要结构化搜索？→ KB
  │     - 是否随产品更新而变、独立于 agent 行为？→ KB
  │   输出: "glossary 350 条 → KB, escalation_keywords → KB"
  │
  └── Step 4: 人类 review + 调整
       Agent 输出建议 → 人类确认/修正 → dispatch template.write
```

#### 冷启动路径（无旧数据）

```
输入: 领域描述 + 产品文档 URL + 1-2 句 bot 目标
  │
  ▼
Template Authoring Agent:
  │
  ├── 从骨架模板开始（6 个通用 section: identity/purpose/gate/escalation/conversation/privacy）
  ├── 分析产品文档 → 预填 soul 内容
  ├── 保守策略: 初始全部标记为 {{slot}}（不确定就先开放）
  ├── 没有 Skill 文件（等试运行后识别提取候选）
  └── 生成 KB 条目（从文档提取术语 → 初始 glossary）
  │
  ▼
试运行 2-3 周:
  ├── 观察哪些 {{slot}} 从未被改过 → 候选锁定为 body
  ├── 观察哪些 soul section 在对话中从未被触发 → 候选提取到 Skill
  │   (通过 transcript review 或 agent response 引用分析，非 Read 调用计数)
  ├── 观察哪些 KB 条目被频繁查询 → 扩充 KB
  └── Template Authoring Agent 分析数据 → 建议收敛 → 人类 review
```

### 1.6 Ezagent 中的表达

**不建新 Kind。不建新 Behavior。全部复用已有机制。**

```
三层                     Ezagent 表达                         编辑方式
────                    ────────────                         ────────
Soul (inline)           AgentTemplate.soul_slot_values       LV → dispatch
  .md 模板文件            (flavor extra — 扩展现有 schema,    template.write
  含 {{key}} 占位符       cc 的 prompt/model 不进 Slice)

Skill (on-disk)     priv/ 下 .md 文件                    直接文件编辑
  可以含 {{key}}         AgentTemplate.skill_slot_values  或 LV (如果需要 slot)
                         (如果需要 slot，同 soul 模式)

KB (queryable)          kb.db + MCP script                   KBCurator Agent
  结构化数据              不进 Slice                          改文件 → 重建 kb.db
```

### 1.7 吸取 AutoService 实施经验

AutoService 基于本 SPEC 做了独立实现 (`docs/superpowers/specs/2026-06-05-soul-reference-kb-design.md`)，提炼了以下改进:

**A. Soul 预算 lint gate**

AutoService 实测 soul 从 1337 行 (~52KB) 瘦身到 ~440 行 (~20KB) (Phase 0-3)。建议增加 CI gate 防止再次膨胀:

| Rule | 阈值 | 行为 |
|------|------|------|
| Soul size warning | > 25KB | WARNING — 建议分析可提取到 Skill 的内容 |
| Soul size error | > 30KB | ERROR — 阻止合入，必须提取或写豁免说明 |

Phase 1 作为 manual check，Phase 3 瘦身后作为 CI gate 加入。

**B. Skill discovery 机制**

AutoService 实现: 加载器扫描 Skill 目录 → 生成索引 → 注入 Soul。ezagent 对应:

```elixir
# cc.agent flavor 的 instantiate/3 内（plugin 层, 非 core 通用步骤）:
# core 的 provision_and_instantiate/4 只分配 config dir，不感知内容
skill_index = build_skill_index(skills_dir())
# 输出:
# ## Skill Index (cc 在需要时 Read 对应文件)
# - 一般产品咨询 → skills/general-inquiry-flow.md
# - Lead 收集流程 → skills/lead-collection-flow.md

# 注入 CLAUDE.md:
claude_md = rendered_soul <> skill_index
# NOTE: Skill 文件体不注入 CLAUDE.md，只有索引。
# cc 看到索引后按需 Read 对应文件。
```

cc 看到索引后按需 Read。新增/删除 Skill 文件 → 需 agent re-spawn（索引在 spawn 时注入）。内容修改 → cc 下次 Read 自动生效。

**C. 路径自带权限边界（AutoService 简化）**

AutoService 去掉了 `editable_by` / `locked_by` 字段 — 文件路径本身决定了编辑权限:

```
路径                                      权限
────                                      ────
priv/<tenant>/soul/soul.md                tenant admin (LV dispatch)
priv/<tenant>/skills/*.md              tenant admin (直接文件编辑)
priv/<tenant>/kb/                         system admin (KBCurator Agent)
master/templates/ (system 模板源)          system admin (git PR)
master/kb/escalation_keywords.json        system admin (git PR)
```

在 ezagent 中，AgentTemplate 的 workspace-scoped CapBAC 已经提供了等效保护。不需要额外 RBAC 字段。

**D. 确认的简化（AutoService 已落地）**

AutoService 实施中去掉了以下内容，与本 SPEC 的设计一致:

| 去掉 | 估算行数 | 原因 |
|------|---------|------|
| priority.yaml + 跨层 lint | ~120 | 后覆盖前足够 |
| `_template_version` + drift detection | ~150 | 渲染保留 raw `{{key}}` 作为信号 |
| `_source_yaml` 间接引用 | ~50 | 直接内联或放 Skill |
| `SOUL_LAYERED_LOADER` 开关 | 2 处 | 已默认 on，退役 |
| sandbox_locks (section 粒度) | ~200 | slot flat map 无跨资源依赖 |
| release_snapshot soul 逻辑 | ~300 | 渲染时产出，不 snapshot |
| skill 概念 | — | 合并入 Skill |
| flow_directive 概念 | — | 合并入 Skill |
| open/guarded Skill 区分 | — | Soul 行为约束替代 |
| **合计** | **~1,027** | |

**E. AutoService vs Ezagent 的关键差异**

| 维度 | AutoService | Ezagent |
|------|-----------|---------|
| 内容来源层级 | Framework / Platform / Industry / Tenant | System / Tenant (2 级，Industry 可延后) |
| 槽位存储 | `slot_values.yaml` 文件 | AgentTemplate slice (flavor extra) |
| 编辑生效 | recycle pool (重 spawn) | agent re-spawn |
| 权限模型 | 路径自带 | workspace-scoped CapBAC (已有) |
| 模板文件位置 | `master/templates/` (git) | `priv/` (plugin 打包) |

**F. 吸取的关键教训**

1. **Phase 0 (KB 提取) 效果显著**: soul 1337→440 行，p50 TTFT 改善 ≥100ms。证明"先提取再迭代"策略正确。
2. **不要过早建 RBAC 字段**: 路径/workspace 已经提供足够边界，`editable_by` 等字段在不需要时就是债务。
3. **渲染时产出优于 snapshot**: soul 是渲染产物，每次 spawn 时重新生成比持久化 snapshot 更简单可靠。
4. **简单文本替换优于复杂模板引擎**: `{{key}}` + flat slot_values 足够覆盖 ~100 个 key 的需求。

## §2 — 模板从哪里来

### 2.1 两条路径

| 路径 | 数据源 | 流程 |
|------|--------|------|
| **迁移** | 旧 `customer_soul.md` + `customer.yaml` | Plugin seed 脚本读取文件 → 解析 `{{key}}` 占位符 → 构建 `slot_values` 默认值 → dispatch `template.write` |
| **冷启动** | 骨架模板（`priv/` 内置）+ 领域文档 | 骨架模板立即可用 → 试运行 → 观察哪些值常被改 → 迭代调整模板文件 |

### 2.2 谁决定模板结构？

**人决定。AI 辅助分析，不自主创建。**

```
LAYER 1: 模板结构（section 划分）  → 人决定，AI 建议
LAYER 2: 哪些是 slot              → 人标记 {{key}}，AI 分析数据建议
LAYER 3: 默认值填什么             → AI 生成初稿，人 review
```

### 2.3 冷启动策略

骨架模板（系统内置 6 个通用 section：identity / purpose / gate / escalation / conversation / privacy）+ 领域注入。所有可配置内容先标记 `{{slot}}` → 试运行 2-3 周 → 观察数据收敛：没人改过的 → 从模板中去掉 `{{}}`（锁定），频繁被改的 → 保留 slot。

---

## §3 — 变更清单：domain 归零

### 3.1 为什么 domain 不需要改

**Slot values 作为 flavor-owned content keys** — 利用已有机制，零 domain 变更。

`AgentTemplate` 的 content 结构本身就是 `universal base + flavor-owned extras`（参见 SPEC 2026-06-01-flavor-generic-template-data, approach B）。每个 flavor 的 Template Class 通过 `template_data_extra/1` 声明额外字段，`to_template_data/2` 自动传给 `instantiate/3`。

```elixir
# 已有机制:
# - AgentTemplate slice content 接受任意 map 结构
# - template.write 接受 %{content: map} → 整体替换
# - template.read 返回完整 content
# - flavor Template Class 通过 template_data_extra/1 声明额外字段
# - to_template_data/2 自动包含这些字段传给 instantiate/3

# soul_slot_values 作为 cc/curl flavor 的
# template_data_extra/1 声明即可，不需要改 agent_template.ex。
# (skills 和 flow chunks 经实测不含 {{slot}}，是纯参考文本，不需要 slot 化)
```

**不需要新 action** — `template.read` + `template.write` 已覆盖编辑流程。

`template.write` 接受 `%{content: map}` 整体替换 slice content。LV 编辑流程：

```
1. template.read → 拿到完整 content（含 slot_values）
2. LV 修改 slot_values 部分
3. template.write → 写回完整 content
```

这就是现有 AgentTemplate LV editor 的编辑模式。模板 body 在 `priv/` 文件中（不在 slice），不存在"tenant 改 body"的风险。`update_slots` action 延后到需要 field-level 强制时。

### 3.2 总览

```
apps/ezagent_core/                              → 0 变更
apps/ezagent_domain_chat/                       → 0 变更

apps/ezagent_plugin_cc/                         → template_data_extra/1 声明新 key
apps/ezagent_plugin_curl_agent/                 → template_data_extra/1 声明新 key
apps/ezagent_plugin_autoservice/                → seed 脚本 + Editor Agent
apps/ezagent_plugin_liveview/                   → LV 槽位编辑面板
```

### 3.3 各 flavor 的 template_data_extra/1

```elixir
# 实际 callback 签名: template_data_extra(content) :: %{String.t() => term()}
# 返回 string-keyed map，不是 atom list。参考:
#   cc_agent.ex:205 / curl_agent.ex:59
#   apps/ezagent_core/lib/ezagent/kind/template.ex:77

# cc flavor: 在现有返回 map 中加 "soul_slot_values" key
def template_data_extra(content) do
  %{
    "claude_config_dir" => content[:claude_config_dir],
    "settings_path"     => content[:settings_path],
    "mcp_config_path"   => content[:mcp_config_path],
    "role"              => content[:role],
    "soul_slot_values"  => content[:soul_slot_values] || %{}   # ← 新增
  }
end

# curl flavor: 同理
def template_data_extra(content) do
  %{
    "provider"          => content[:provider],
    "api_url"           => content[:api_url],
    "model"             => content[:model],
    "system_prompt"     => content[:system_prompt],
    "max_history"       => content[:max_history],
    "soul_slot_values"  => content[:soul_slot_values] || %{}   # ← 新增
  }
end
```

**这就是全部"新增"—— 每个 flavor 的 template_data_extra 加 1 个 key。**

---

## §4 — 文件布局约定

### 4.1 三层文件布局

```
apps/ezagent_plugin_autoservice/priv/<tenant>/
  soul/
    soul.md                    ← Soul 模板（始终 inline, 含 {{key}}）
  skills/
    general-inquiry-flow.md    ← Skill（按需 Read, 可选 {{key}}）
    bug-routing-flow.md
    lead-collection.md         ← 合并旧 flow_chunks + skills
    partner-handoff.md
    ... (数量由模板作者决定)
  kb/
    kb.db                      ← SQLite 知识库
    kb_search_mcp.py           ← MCP server
    escalation_keywords.json   ← KB 工具配置（不进 Slice）
```

### 4.2 Soul 模板（含 {{slot}}）

```markdown
# {{identity.bot_full_name}}

你是 **{{identity.bot_full_name}}**，嵌入在 {{identity.host_site_descriptor}} 网站。

遇到价格问题时: "{{gate.escalation_phrase}}"

## Skill Index（agent 遇到对应场景时 Read 对应文件）
- 一般产品咨询 → skills/general-inquiry-flow.md
- Bug 报告 → skills/bug-routing-flow.md
- Partner/渠道 → skills/partner-handoff.md
```

### 4.3 Skill 文件（可选 {{slot}}）

由模板作者决定是否需要 slot。示例 — 如果分析发现 `retry_limit` 跨租户可变:

```yaml
---
name: general-inquiry-flow
description: Existing customer path A — answer from KB with retry
slots:
  retry_limit: {type: integer, default: 2, max: 5}
---

# Flow: General Product Inquiry

## retry={{retry_limit}} hard limit

- Customer asks. Answer from KB.
- "still not right" ({{retry_limit}}nd negative) → recap + handoff.
```

如果分析发现 retry_limit 在所有租户中都是 2 → 不需要 slot，硬编码在文本中。

### 4.4 分离决策记录

每次 Template Authoring Agent 分析后，在文件头部 YAML 记录决策:

```yaml
---
separation:
  analyzed_at: 2026-06-04
  analyzed_by: "entity://user/system/admin"
  decisions:
    - {item: "retry_limit", from: "customer.yaml:existing-product-pointer", 
       to: "slot:skills/general-inquiry-flow.retry_limit", reason: "跨租户可变"}
    - {item: "lead_collection_flow", from: "soul §6 + flow_chunks/cinnox-flow-lead-new.md",
       to: "skills/lead-collection.md", reason: "体积 >3KB, 仅 new_customer 场景需要"}
    - {item: "escalation_phrase", from: "customer.yaml:gate",
       to: "slot:soul.gate.escalation_phrase", reason: "smoke contract, 必须在 inline soul"}
```

---

## §5 — 编辑流程

### 5.1 Tenant 编辑（修改槽位值）

```
Tenant Admin LV
  │
  │ 展示: 从模板文件解析出的 slot key 列表
  │   identity.bot_full_name        [CINNOX AI Bot        ]
  │   identity.host_site_descriptor [CINNOX/M800          ]
  │   gate.escalation_phrase        [这个具体数字...       ]
  │   ... (全部 text input — 第一版不做类型约束)
  │
  │ admin 修改 → LV:
  │   1. dispatch ?action=template.read → 完整 content
  │   2. 修改 content 中的 soul_slot_values
  │   3. dispatch ?action=template.write → 写回完整 content
  ▼
AgentTemplate slice 更新

→ agent 重新 spawn → Template Class 重新渲染 → 新值生效
```

**为什么用 `template.write` 而不是新 action:**

模板 body 在 `priv/` 文件中，不在 AgentTemplate slice content 里。tenant 通过 `template.write` 能改的字段（slot_values）恰恰是需要他改的。`template.write` 改 `default_caps` 等敏感字段的风险通过已有 CapBAC 控制（P15: workspace-scoped cap）。

### 5.2 System 编辑（修改模板结构）

```
System Admin
  │
  │ 直接改 priv/ 下的 .md 模板文件（增加 section、调整 {{key}}、锁定 body）
  │ → plugin 重新部署（或热加载）
  │ → 新 fork 的 tenant 自动获得新模板文件
  │ → 已有 tenant 的 agent 需重新 spawn（见 §7.2）
  ▼
新模板文件 + 已有 slot_values → render_slots 渲染
```

### 5.3 AI Editor Agent

Editor Agent 是普通的 cc agent（system workspace），通过:
- dispatch `template.read` / `template.write` 操作切片值
- bash/read/write 工具操作模板文件

---

## §6 — 渲染流程

### 6.1 cc agent

```elixir
# cc_agent.ex :instantiate/3 扩展:

def instantiate(template_data, uri, ctx) do
  # 1. 渲染 soul 模板（唯一需要 slot 填充的）
  soul_template = File.read!(soul_template_path())
  soul_values = template_data["soul_slot_values"] || %{}
  rendered_soul = render_slots(soul_template, soul_values)

  # 2. Skill 文件 — 直接复制（是否需要 render_slots 取决于有无 {{slot}}）
  copy_files(skills_dir(), agent_workdir)

  # 3. 写入 agent sandbox
  write_claude_md(rendered_soul, skill_index)
end
```

### 6.2 curl agent

同样流程。Soul 渲染后写入 `system_prompt`；skills/flow chunks 如需要则在 prompt 中列出索引。

### 6.3 模板文件来源

```
System ROOT 模板:
  → 从 plugin priv/ 读取（随着 plugin 部署）

Tenant Fork:
  → parent_template_uri 指向 system ROOT
  → Template Class 从 parent 的 priv/ 或已知路径读取模板文件
  → 或者 seed 时将模板文件 copy 到 tenant 工作目录
```

---

## §7 — 模板更新传播

### 7.1 最小模型

模板文件更新（system admin 改 `priv/` 文件）→ 新 fork 的 tenant 自动获得新模板文件。已有 tenant 的 agent：
- **需重新 spawn**（而非 restart）才能获取新模板。
- 原因: cc agent 重启走 `Sandbox.activate/2`，从 durable snapshot 恢复 `respawn_template_data`，不会重新调 `template.instantiate`（Codex r9 HIGH-2 确认）。
- 重新 spawn 后: Template Class 读取新模板文件 + 已有 slot_values → 渲染。

### 7.2 约束与延后

| 项目 | 说明 |
|------|------|
| **模板更新需 re-spawn** | 当前架构限制。未来可加 re-instantiate 路径让 agent 重启时自动获取新模板 |
| 自动推送通知 | 延后，需要 `NotificationSubscriptions` + LV 集成 |
| 自动 merge + 冲突检测 | 延后，手动 merge 成本低 |
| touched_slots 追踪 | 延后 |

---

## §8 — KB 管理（含 soul→KB 提取的内容）

KB 保持当前模式：`kb.db` SQLite + Python MCP script。原因:
- 已工作，编辑频率极低
- MCP server 始终读最新数据
- 升级到 Resource Kind 是纯增量

### 8.1 KB 包含的内容

| 内容 | 来源 | 谁改 | 频率 |
|------|------|------|------|
| **glossary** (350 术语) | 产品文档 | System admin (KBCurator Agent 辅助) | 低（产品变更时） |
| **synonym-map** (术语别名) | 从搜索日志分析 | System admin | 低 |
| **escalation_keywords** | **从 Soul 剥离** | System admin | **极低**（安全约束） |

### 8.2 escalation_keywords 的特殊处理

这些关键词原来在 Soul 的规则文本中（"遇到价格/SLA/合同问题 → 升级"），旧系统提取到 `kb_escalation_keywords.json`，由 `kb_search` MCP tool 读取并执行 short-circuit 检测。

在 ezagent 中:
- **位置**: KB 侧 — 随 kb.db 或 MCP config 文件分发
- **SoT**: 独立的 JSON 文件（与旧系统相同），seed 时随 kb.db 一起部署
- **编辑**: KBCurator Agent 通过文件操作修改
- **不可 slot 化**: 升级关键词是安全约束，不应由 tenant 定制
- **Soul 引用**: soul 模板 body 中写 "如果 kb_search 返回 escalate_required → 直接说 {{gate.escalation_phrase}} 并停止" — soul 定义行为策略，KB 定义触发条件

### 8.3 为什么 escalation_keywords 不进 AgentTemplate slice

- 它是 **KB 工具的内部配置**，不是 agent 的配置
- kb_search MCP tool 需要读取它来执行 short-circuit 逻辑
- 如果放在 AgentTemplate slice，MCP tool 需要通过 dispatch 读取 — 增加不必要的耦合
- 放在 KB 侧保持"KB 工具自包含"的原则

---

## §9 — 实施序列

### Phase 1 — 核心链路（2 天）

| # | 文件 | 任务 | Tier |
|---|------|------|------|
| 1 | `cc_agent.ex` | `template_data_extra/1` 加 `:soul_slot_values` | plugin cc |
| 2 | `curl_agent.ex` | 同上 | plugin curl |
| 3 | `cc_agent.ex` | `render_slots/2` + instantiate 调它；skills/flow_chunks 直接 copy（不需要 render_slots） | plugin cc |
| 4 | `curl_agent.ex` | 同上 | plugin curl |
| 5 | `cinnox_assets.ex` | 模板文件放在 `priv/cinnox/souls/` + `skills/` + `flow_chunks/`；seed 时 copy 到 agent workdir | plugin autoservice |
| 6 | `seed_autoservice.ex` | seed 时从旧 yaml 提取默认值 → dispatch `template.write` 写入 `soul_slot_values` | plugin autoservice |

### Phase 2 — LV 编辑 + Editor Agent（2 天）

| # | 任务 | Tier |
|---|------|------|
| 1 | LV: 解析模板文件 `{{key}}` → 生成 text input 表单 → `template.read` + 修改 + `template.write` | LV |
| 2 | LV: 展示当前值 vs 默认值对比 | LV |
| 3 | SkillEditor / SoulDesigner Agent seed（cc agent，system ws） | plugin autoservice |

### Phase 3 — Template Authoring Agent（1-2 天）

| # | 任务 | Tier |
|---|------|------|
| 1 | Authoring Agent seed（cc agent，操作文件 + dispatch `template.read`/`write`） | plugin autoservice |
| 2 | LV: Authoring Console | LV |

### 总 LOC 估算

| Tier | 新增 | 修改 | LOC |
|------|------|------|-----|
| **core** | 0 | 0 | **0** |
| **domain** | 0 | 0 | **0** |
| **plugin** | 2 (Editor Agent seed) | 3 (cc/curl/cinnox_assets) | **~180** |
| **LV** | 0 | 2 (slot editor + authoring console) | **~200** |
| | | | **~380** |

---

## §10 — 完整数据流

```
┌──────────────────────────────────────────────────────────────────────┐
│  CREATE                                                               │
│                                                                       │
│  priv/cinnox/souls/customer_soul.md  (含 {{identity.name}} 等占位符)  │
│  priv/cinnox/skills/customer/*/SKILL.md                               │
│      │                                                                │
│      │ seed 脚本解析 {{key}} + 从旧 yaml 提取默认值                    │
│      ▼                                                                │
│  AgentTemplate (system ws)                                            │
│    parent_template_uri: nil                                           │
│    soul_slot_values: %{"identity.name" => "CINNOX AI", ...}          │
│      │                                                                │
│      │ fork (Behavior.Template :fork — 已有)                           │
│      ▼                                                                │
│  AgentTemplate (tenant ws)                                            │
│    parent_template_uri: system/...                                     │
│    soul_slot_values: %{"identity.name" => "我的品牌", ...}           │
│                                                                       │
├──────────────────────────────────────────────────────────────────────┤
│  EDIT                                                                 │
│                                                                       │
│  Tenant LV                                                             │
│    → dispatch ?action=template.read → 完整 content                     │
│    → 修改 soul_slot_values                                             │
│    → dispatch ?action=template.write → 写回完整 content                │
│                                                                       │
│  System admin                                                          │
│    → 直接改 priv/ 下 .md 文件（+ 新增 {{key}}、调整 body 文本）        │
│    → LV 上 template.write 更新默认 slot_values（新增 slot 的默认值）   │
│                                                                       │
├──────────────────────────────────────────────────────────────────────┤
│  RENDER                                                               │
│                                                                       │
│  Template Class.instantiate:                                           │
│    body = File.read!(模板文件)                                         │
│    rendered = render_slots(body, slot_values)                         │
│    → CLAUDE.md (cc) / system_prompt (curl)                            │
│    → 未填 slot → raw {{key}} 保留（可见的"未配置"信号）                 │
│                                                                       │
├──────────────────────────────────────────────────────────────────────┤
│  PROPAGATE                                                            │
│                                                                       │
│  System 更新模板文件:                                                   │
│    → 新 fork 的 tenant → 新模板文件                                     │
│    → 已有 tenant → 需 agent re-spawn（非 restart）获取新模板            │
│    → 新增 {{key}}: 渲染为占位符（"未配置"）                             │
│    → 删除 {{key}}: tenant 旧值被忽略                                    │
│    → 保留 {{key}}: tenant 值继续生效                                    │
└──────────────────────────────────────────────────────────────────────┘
```

---

## §11 — 不变式自查

- [ ] **P1**: core 零变更 ✅
- [ ] **P8**: 不建新 Kind/Behavior。复用 AgentTemplate + Behavior.Template（已有 `:read` / `:write` action）✅
- [ ] **P3**: 槽位值 SoT = AgentTemplate slice content (flavor-owned keys)。模板 SoT = `priv/` 文件。渲染产物（CLAUDE.md、skills/*.md）是 **projection/cache**，由 agent spawn 时从 SoT 重新生成 ✅
- [ ] **P14**: 编辑走 dispatch `?action=template.read` / `?action=template.write` ✅
- [ ] **P20**: 不引入新 scheme ✅
- [ ] **P26**: fork = config only（slot_values 复制）✅
- [ ] **Codex r9 HIGH-2 闭合**: 明确模板更新需 agent re-spawn（非 restart），因为 cc agent 重启走 Snapshot 而非 re-instantiate ✅
- [ ] **Codex r9 MEDIUM-2 闭合**: 渲染产物标记为 projection/cache，SoT 是 `priv/` 文件 + slice slot_values ✅
- [ ] **Codex r9 MEDIUM-3 闭合**: seed 脚本跳过 `_` 前缀的 yaml key（system metadata），不转为 slot ✅

---

## §12 — 延后清单（记录以防止实施时 scope creep）

| 功能 | 延后理由 | 解锁条件 |
|------|---------|---------|
| `soul_template_body` 进 slice | 文件模式已工作，slice 会增加 snapshot 体积 | 需要跨 workspace 共享模板正文时 |
| `slot_schema` 进 slice（类型约束） | 第一版 text input 足够；schema 可后续从文件 YAML header 解析 | 需要 enum 下拉 / max_length 约束时 |
| `lifecycle_state` | 还没做模板发布流程 | 做 LV 模板管理面板时 |
| `skill_origin` | tenant 还没能力自创 skill | 做 skill 创建功能时 |
| `propagated_from_version` | 传播先用手动模式 | 做自动传播时 |
| 自动模板更新通知 | 手动重启生效够用 | 需要实时推送时 |
| KB 升级到 Resource Kind | MCP 文件模式已工作 | 需要独立 CapBAC + audit trail 时 |

---

## §13 — 潜在风险与待审查问题

1. **`template.write` 是整体替换**: tenant 持有 `template:write` cap 可通过 `:write` action 改 AgentTemplate 任意字段（如 `default_caps`）。模板 body 在 `priv/` 文件中不受影响。当前通过 workspace-scoped cap + LV 约定约束 — 不提供 server-side 字段级 enforce。延后到需要时加 `update_slots` action。Codex r9 HIGH-1 认可此风险在 MVP 可接受。
2. **Slot key 注入**: `{{key}}` 是 tenant 不可控的（在模板文件中），但 key 本身可能包含敏感路径（如 `{{../../../etc/passwd}}`）。`render_slots` 的 regex `[a-z][a-z0-9_.-]*` 限制了合法字符集，阻止路径遍历。
3. **Slot value 注入**: tenant 填的值会被注入 LLM system prompt。值越界可能让 agent 行为偏离。第一版通过 key 白名单 + 全 text 类型（无执行语义）降低风险。后续加 max_length 和 content sanitization。
4. **未填 slot 泄露**: 渲染后保留 `{{key}}` 让 agent 看到。如果 key 名包含敏感信息（如 `{{internal.pricing_api_key}}`），这会泄露到 agent prompt 中。
5. **模板文件与 slice 不一致**: system admin 在文件新增 `{{new_key}}` 但忘了 seed 默认值。渲染时 `new_key` 显示为 raw `{{new_key}}`，是可见信号但非 fail-loud。
