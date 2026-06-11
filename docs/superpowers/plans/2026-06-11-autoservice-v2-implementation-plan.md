# AutoService v2 on ezagent — 实施计划

> 基于 [`2026-06-10-autoservice-v2-design.md`](../specs/2026-06-10-autoservice-v2-design.md) §10
> 配套设计: /home/huangjiajia/ezagent/docs/superpowers/specs/2026-06-10-autoservice-v2-design.md
> 状态: **Plan v2** | 日期: 2026-06-11
> 
> **核心约束: core 0 / domain 0 改动，所有实现在 plugin 层。**

---

## 总览

```
Phase A: content + cr plugin, Cinnox 迁移 (~22 新文件)  ← 本期核心
Phase B: autoservice 精简 + Turn/CustomerFeed 接入 (~10 改动)
Phase C: Admin UI 补齐 (~8 新文件)
Phase D: FillerLoop + 优化 (~2 文件，可 defer)

依赖: Phase A → Phase B → Phase C → Phase D
      Phase A 内部可并行: A1-A5 (content) || A6 (cr)
      A7-A8 依赖 A1-A6
```

---

## Phase A: content + cr plugin（本期核心）

### 目标

1. 从 autoservice plugin 提炼通用内容管理为 `ezagent_plugin_content`
2. 新建 `ezagent_plugin_cr` 实现 CR 发布流
3. Cinnox 数据从旧 `priv/cinnox/` 迁移到新 runtime 路径
4. agent 配置从硬编码改为从配置文件读取

### Task A1: ezagent_plugin_content — 基础骨架

**产出**: `apps/ezagent_plugin_content/` 完整目录结构 + 平台模板

**参考设计**:
- §2.1 拆分设计 — plugin 模块划分
- §3.2.1 存储分层 — priv/ vs runtime 路径
- §3.5 Agent 配置 — 平台默认配置

**实施清单**:

```
apps/ezagent_plugin_content/
├── mix.exs                                          # 依赖: ezagent_core, ezagent_domain_socialware (ConfigStore)
├── lib/
│   ├── ezagent_plugin_content.ex                    # 顶层模块, 版本信息
│   └── ezagent_plugin_content/
│       └── application.ex                           # OTP Application + Plugin contract
├── priv/
│   ├── skeleton/
│   │   ├── soul/
│   │   │   └── soul.md                              # 新租户默认 soul 模板 (含 {{key}})
│   │   ├── skills/
│   │   │   └── .gitkeep
│   │   ├── kb/
│   │   │   └── .gitkeep
│   │   └── config/
│   │       ├── agents.yaml                          # 平台默认 agent 配置
│   │       ├── fast_ack_prompt.md                   # 默认 fast ACK prompt
│   │       └── cc_preamble.md                       # 默认 cc CLAUDE.md preamble
│   └── platform/
│       ├── framework/customer/soul.md               # L0 Framework soul
│       ├── platform/customer.md                     # L1 Platform soul
│       ├── industry/cloud-comms/customer/soul.md    # L2 Industry soul (cinnox 示例)
│       ├── templates/customer/soul.md               # L3 模板 (含 {{key}})
│       ├── skills/
│       │   └── customer/
│       │       ├── customer-type-clarifier/SKILL.md
│       │       ├── lead-collection-flow/SKILL.md
│       │       ├── discovery-questions/SKILL.md
│       │       └── ...                              # 从 autoservice priv/cinnox/skills/ 迁移
│       └── industry/cloud-comms/skills/             # L2 Industry skill 示例
│           └── ...
└── test/
    ├── test_helper.exs
    └── ezagent_plugin_content/                      # 后续 task 填充
```

**agents.yaml 格式**:

```yaml
# 平台默认 agent 配置 (master admin 管控, 租户不可覆盖)
fast:
  model: deepseek-v4-flash
  endpoint: https://api.deepseek.com/chat/completions
  max_tokens: 256
  thinking: disabled
slow:
  model: deepseek-v4-flash
  effort: low       # PR #715 live finding: low 即可 ~26s
```

**关键决策**:
- agent 环境配置 (model, endpoint, API key) 由 master 管控，不进 CR
- prompt 模板 (fast_ack_prompt.md, cc_preamble.md) 租户可编辑，走 CR
- skeleton 作为新租户基线，创建时复制到 runtime 路径

**验收**:
- `mix compile` — plugin 编译通过
- `Application.app_dir(:ezagent_plugin_content, "priv")` 可访问 skeleton 和 platform 目录

---

### Task A2: ezagent_plugin_content — Soul CRUD

**产出**: `soul/` 子模块 4 文件 + 单元测试

**参考设计**: §3.2.2 Soul 渲染流程, §3.2.3 Skill 文件格式, §8.2 Soul 编辑

**模块接口定义**:

```elixir
# soul_loader.ex — 4 层加载 (§3.2)
@spec load(tid :: String.t(), role :: String.t()) :: [binary()]
# 返回合并后的 soul 列表 [L0, L1, L2, L3_template, tenant_override]
# 加载顺序: tenant runtime > industry > platform > framework
# 后覆盖前合并
def load(tid, role)
  # 遍历 4 层目录:
  #   1. priv/platform/framework/<role>/soul.md      (L0)
  #   2. priv/platform/platform/<role>.md            (L1)
  #   3. priv/platform/industry/<industry>/<role>/soul.md (L2)
  #   4. priv/platform/templates/<role>/soul.md      (L3 模板)
  #   5. runtime/tenants/<tid>/sandbox/souls/<role>_soul.md (租户覆盖, 如有)
  # 后覆盖前: 同 section 的 {{key}} 以后出现的为准
  # 返回: 合并后单一 soul binary

# soul_slot_parser.ex — 解析 {{key}} (§3.2.2)
@spec parse_slots(soul_template :: binary()) :: [
  %{section: String.t(), keys: [String.t()], raw: binary()}
]
def parse_slots(template)
  # 按 ## section 标题分组
  # 提取每组内的 {{key}} (正则: \{\{[a-z][a-z0-9_.-]*\}\})
  # 返回 section 列表, 每个含 section 名 + key 列表 + 原始文本

# soul_renderer.ex — {{slot}} 渲染 (§3.2.2)
@spec render(templates :: [binary()], slot_values :: map()) :: binary()
def render(templates, slot_values)
  # 合并所有模板 (后覆盖前)
  # {{identity.bot_full_name}} → Map.get(slot_values, "identity", %{})["bot_full_name"]
  # 缺失 key 保留 raw {{key}} 作为 "未配置" 信号
  # 注意: 嵌套 key "identity.bot_full_name" 需要按 "." 分割后逐级取值

@spec full_claude_md(tid :: String.t(), role :: String.t(), slot_values :: map()) :: binary()
def full_claude_md(tid, role, slot_values)
  # 1. 读 cc_preamble (release/_current/config/cc_preamble.md → sandbox/config/)
  # 2. load(tid, role) 取模板
  # 3. render(templates, slot_values) 渲染
  # 4. skill_indexer.build(tid, role) 生成 Skill Index
  # 5. 拼接: preamble + 渲染后 soul + skill_index

# soul_store.ex — slot_values CRUD (§8.2)
@spec read_slots(tid :: String.t(), role :: String.t(), source :: :sandbox | :release) ::
        {:ok, map()} | {:error, term()}
def read_slots(tid, role, :sandbox)
  # 读 sandbox/slots/<role>.yaml → map
def read_slots(tid, role, :release)
  # 读 release/_current/slots/<role>.yaml → map

@spec write_slots(tid :: String.t(), role :: String.t(), values :: map()) ::
        :ok | {:error, term()}
def write_slots(tid, role, values)
  # 写 sandbox/slots/<role>.yaml
  # 保留已有 key, 只更新传入的 key (merge, 不整体替换)
  # 写后通知: cr_engine.track_change(tid, {:soul_slot, role, section_id})

@spec defaults(tid :: String.t(), role :: String.t()) :: map()
def defaults(tid, role)
  # 从 priv/skeleton/soul/soul.md 解析 {{key}}
  # 返回 map: %{"identity.bot_full_name" => "", "identity.host_site_descriptor" => "", ...}
  # 所有 value 为空字符串 — 等 tenant admin 填充
```

**测试清单** (放在 `test/ezagent_plugin_content/soul/`):

```
soul_loader_test.exs:
  - test "4 层加载, 后覆盖前合并"
  - test "租户覆盖优先于平台"
  - test "缺失层不影响加载"
  - test "空租户目录只用平台模板"

soul_slot_parser_test.exs:
  - test "解析 {{key}} 按 section 分组"
  - test "多 section 各自独立"
  - test "无 {{key}} 的 section 返回空 key 列表"
  - test "异常 key 格式 (大写/数字开头) 被忽略"

soul_renderer_test.exs:
  - test "{{key}} 正确替换"
  - test "缺失 key 保留 raw {{key}}"
  - test "嵌套 key identity.bot_full_name 正确取值"
  - test "full_claude_md 含 preamble + soul + skill_index"
  - test "4 层模板合并后渲染"

soul_store_test.exs:
  - test "read_slots sandbox vs release 读不同路径"
  - test "write_slots merge 已有 key, 不整体替换"
  - test "defaults 从 skeleton 模板解析"
```

**前置**: A1 (skeleton + platform 模板就位)

**验收**: `mix test test/ezagent_plugin_content/soul/` — 全部绿 (~16 tests)

---

### Task A3: ezagent_plugin_content — Skill CRUD

**产出**: `skill/` 子模块 3 文件 + 单元测试

**参考设计**: §3.3 Skill, §8.3 Skill 管理

**模块接口定义**:

```elixir
# skill_loader.ex — 4 层扫描 (§3.3)
@type layer :: :framework | :platform | :industry | :tenant
@type skill_entry :: %{name: String.t(), path: String.t(), layer: layer()}

@spec list(tid :: String.t(), role :: String.t(), layer :: layer()) :: [skill_entry()]
def list(tid, role, layer)
  # :framework → priv/platform/skills/<name>/SKILL.md
  # :platform  → priv/platform/skills/<name>/SKILL.md
  # :industry  → priv/platform/industry/<industry>/skills/<name>/SKILL.md
  # :tenant    → runtime/tenants/<tid>/sandbox/skills/<role>/<name>/SKILL.md
  # 同名文件: tenant > industry > platform > framework

# skill_indexer.ex — 生成 Skill Index (§3.3, §8.3)
@spec build(tid :: String.t(), role :: String.t()) :: binary()
def build(tid, role)
  # 扫描 4 层, 同名用最高优先
  # 读取每个 SKILL.md 的 YAML frontmatter (name, description)
  # 生成:
  #   ## Skill Index
  #   需要时 Read 对应文件:
  #     - **Lead 收集流程** — skills/customer/lead-collection-flow/SKILL.md: Lead 收集 — 4 字段逐步询问
  #     - **Bug 报告路由** — skills/customer/bug-routing-flow/SKILL.md: Bug 报告路由
  # agent work dir symlink 结构: plugins/<tid>/skills/ → release/_current/skills/
  # Index 中路径是相对路径, cc agent Read 时通过 symlink 解析

# skill_store.ex — CRUD (§8.3)
@spec read(tid :: String.t(), role :: String.t(), name :: String.t()) ::
        {:ok, binary()} | :not_found
def read(tid, role, name)
  # 最高优先层找到即返回 (tenant > industry > platform > framework)

@spec write(tid :: String.t(), role :: String.t(), name :: String.t(), content :: binary()) :: :ok
def write(tid, role, name, content)
  # 写 sandbox/skills/<role>/<name>/SKILL.md
  # 通知: cr_engine.track_change(tid, {:skill, name})

@spec delete(tid :: String.t(), role :: String.t(), name :: String.t()) :: :ok
def delete(tid, role, name)
  # 删除 sandbox/skills/<role>/<name>/SKILL.md
  # 通知: cr_engine.track_change(tid, {:skill, name})
```

**测试清单** (放在 `test/ezagent_plugin_content/skill/`):

```
skill_loader_test.exs:
  - test "4 层扫描各自返回正确路径"
  - test "同名 skill tenant 覆盖 platform"
  - test "不存在的层返回空列表"

skill_indexer_test.exs:
  - test "扫描生成 Skill Index markdown"
  - test "同名 skill 取最高优先级"
  - test "YAML frontmatter 解析 name + description"
  - test "无 frontmatter 的 skill 降级处理"

skill_store_test.exs:
  - test "read 同名取最高优先"
  - test "write 写 sandbox, 不覆盖 platform"
  - test "delete 只删 sandbox, 不删 platform"
```

**前置**: A1 (platform skill 模板就位), 测试需临时创建 sandbox 目录

**验收**: `mix test test/ezagent_plugin_content/skill/` — 全部绿 (~10 tests)

---

### Task A4: ezagent_plugin_content — KB CRUD

**产出**: `kb/` 子模块 4 文件 + 迁移 kb_curator_agent

**参考设计**: §3.4 KB, §8.4 KB 管理, §3.5 MCP 配置

**模块接口定义**:

```elixir
# kb_store.ex — 条目 CRUD (§8.4)
@type kb_entry :: %{id: String.t(), content: binary(), source: String.t(), updated_at: DateTime.t()}

@spec search(tid :: String.t(), query :: String.t()) :: [kb_entry()]
def search(tid, query)
  # 调 Python MCP script:
  #   uv run --script kb_search_mcp.py --db-path <sandbox/kb/kb.db> --query <query>
  # 返回 JSON 解析后的结果列表
  # 注: production agent 读 release/_current/kb/kb.db, admin search 读 sandbox/kb/kb.db

@spec get(tid :: String.t(), entry_id :: String.t()) :: {:ok, kb_entry()} | :not_found
def get(tid, entry_id)
  # 同上, 精确查询

@spec upsert(tid :: String.t(), entry :: map()) :: :ok | {:error, term()}
def upsert(tid, entry)
  # 调 Python: uv run --script kb_search_mcp.py --db-path <sandbox/kb/kb.db> --upsert '<json>'
  # 写 sandbox/kb/kb.db (不是 release)
  # 通知: cr_engine.track_change(tid, {:kb, :entry, entry_id})

@spec delete(tid :: String.t(), entry_id :: String.t()) :: :ok | {:error, term()}
def delete(tid, entry_id)
  # 同上, delete

# kb_rebuilder.ex — kb.db 重建 (§8.4)
@spec rebuild(tid :: String.t()) :: :ok | {:error, term()}
def rebuild(tid)
  # 调 Python:
  #   uv run --script kb_search_mcp.py --rebuild
  #     --db-path <sandbox/kb/kb.db>
  #     --glossary <sandbox/kb/glossary.json>
  #     --synonyms <sandbox/kb/synonym-map.json>
  #     --sources <sandbox/kb/_sources/>

# kb_mcp_provider.ex — MCP 配置生成 (§3.4, §3.5)
@spec config(tid :: String.t()) :: binary()
def config(tid)
  # 生成 .mcp.json 内容:
  #   {"mcpServers": {"<tid>-kb": {"command": "uv", "args": ["run", "--script", "<sandbox>/kb/kb_search_mcp.py"], "env": {"KB_DB_PATH": "<release>/_current/kb/kb.db"}}}}
  # 注: production agent 的 MCP 配置中 KB_DB_PATH 指向 release, 不是 sandbox

# kb_curator_agent.ex — 从 autoservice plugin 迁移 (§8.2.5)
# 全文件迁移, 更新路径引用:
#   CinnoxAssets.soul_path → 不变(agent 是 cc agent, 无所谓)
#   CinnoxAssets.kb_db_path → tenant_runtime.path(tid, :sandbox) <> "/kb/kb.db"
#   CinnoxAssets.root → 移除(不暴露 vendor 路径)
```

**URL 抓取 + 文件上传** (§8.4):

```elixir
@spec fetch_url(tid :: String.t(), url :: String.t()) :: :ok | {:error, term()}
def fetch_url(tid, url)
  # 调 Python: uv run --script kb_search_mcp.py --fetch-url <url> --db-path <sandbox/kb/kb.db>
  # 记录 _sources/_sources.yaml: {url: {type: "url", path: url, friendly_name: url, ingested_at: now, hash: sha256(content)}}
  #   friendly_name 默认取 URL last segment, admin 可在 UI 修改
  # 去重: 先查 _sources hash, 相同则 skip
  # 通知: cr_engine.track_change(tid, {:kb, :source, url})

@spec ingest_file(tid :: String.t(), file_path :: String.t()) :: :ok | {:error, term()}
def ingest_file(tid, file_path)
  # 上传 .pdf/.xlsx/.md/.txt
  # 调 Python: uv run --script kb_search_mcp.py --ingest-file <file_path> --db-path <sandbox/kb/kb.db>
  # 记录 _sources/_sources.yaml, 去重
```

**_sources 管理**:

```yaml
# sandbox/kb/_sources/_sources.yaml
cinnox-pricing-2026:
  type: url
  path: https://example.com/pricing.pdf
  friendly_name: "CINNOX 产品价目表(2026版)"
  ingested_at: "2026-06-11T10:00:00Z"
  hash: "sha256:abc123..."
```

**测试清单** (放在 `test/ezagent_plugin_content/kb/`):

```
kb_store_test.exs:
  - test "search 调 MCP script 返回结果"
  - test "upsert/delete CRUD 循环"
  - test "fetch_url 记录 _sources 去重"

kb_rebuilder_test.exs:
  - test "rebuild 从 glossary+sources 重建 kb.db"

kb_mcp_provider_test.exs:
  - test "config 生成正确 MCP JSON"
  - test "KB_DB_PATH 指向 release 不是 sandbox"
```

**前置**: A1 (Python MCP scripts vendored), 测试需 Python/uv 可用或 mock

**验收**: `mix test test/ezagent_plugin_content/kb/` — 全部绿 (~12 tests)

---

### Task A5: ezagent_plugin_content — Tenant 管理

**产出**: `tenant/` 子模块 3 文件 + `platform/` 子模块 3 文件 + 单元测试

**参考设计**: §9 租户生命周期, §3.2.1 存储分层, §4.4 用户管理流程

**模块接口定义**:

```elixir
# tenant_runtime.ex — 运行时路径管理 (§3.2.1, §5.1)
@spec base_dir() :: binary()
def base_dir
  # ~/.ezagent/<profile>/tenants/

@spec path(tid :: String.t(), area :: :sandbox | :release, args :: [binary()]) :: binary()
def path(tid, :sandbox, subpath)
  # base_dir() <> "/<tid>/sandbox/" <> Enum.join(subpath, "/")
def path(tid, :release, subpath)
  # base_dir() <> "/<tid>/release/_current/" <> Enum.join(subpath, "/")

@spec materialize(tid :: String.t(), role :: String.t(), source :: :sandbox | :release) :: binary()
def materialize(tid, role, source)
  # 创建 agent work dir: base_dir() <> "/<tid>/cc-agents/<role>-work/"
  # 渲染 CLAUDE.md → work dir (从 source 对应路径读模板+slots)
  # symlink skills/ → path(tid, source, ["skills", role])
  # symlink kb.db → path(tid, source, ["kb", "kb.db"])
  # 生成 .mcp.json (KB_DB_PATH 指向 source 路径)
  # 返回 work_dir 路径

# tenant_provisioner.ex — 租户创建 (§9.1)
@spec create_tenant(tid :: String.t(), brand_name :: String.t(), opts :: keyword()) ::
        {:ok, %{workspace_uri: URI.t(), admin_uri: URI.t(), cr_id: String.t()}}
        | {:error, term()}
def create_tenant(tid, brand_name, opts)
  # Step 1: 创建 workspace://<tid>
  # Step 2: 创建 entity://user/<tid>/admin + tenant_admin caps
  # Step 3: 文件系统初始化
  #   - cp -r priv/skeleton/ → sandbox/
  #   - uv run kb_search_mcp.py --init-empty → sandbox/kb/kb.db
  #   - 写默认 escalation_keywords.json, glossary.json (空)
  # Step 4: ConfigStore 写入 tenant:<tid>:config
  # Step 5: 创建首个 CR (scope=全部, status=open)
  # 返回 workspace_uri, admin_uri, cr_id

# tenant_config.ex — 租户配置 (§9.2)
@spec read(tid :: String.t()) :: {:ok, map()} | :not_found
def read(tid)
  # ConfigStore 读 tenant:<tid>:config

@spec write(tid :: String.t(), config :: map()) :: :ok | {:error, term()}
def write(tid, config)
  # ConfigStore 写 tenant:<tid>:config

# platform_soul_store.ex — 平台模板 CRUD (§2.1)
# 读写 priv/platform/ 下的 soul 模板 (master admin, 走 git)

# platform_skill_store.ex — 平台 skill CRUD (§2.1)
# 读写 priv/platform/ 下的 skill 文件

# platform_kb_store.ex — escalation_keywords 管理 (§2.1)
# 读写 priv/platform/ 下的 escalation_keywords 模板
```

**测试清单** (放在 `test/ezagent_plugin_content/tenant/`):

```
tenant_runtime_test.exs:
  - test "path 返回正确 sandbox/release 路径"
  - test "materialize 创建 agent work dir + symlink"
  - test "materialize 用 release 路径时 symlink 指向 release/_current"

tenant_provisioner_test.exs:
  - test "create_tenant 创建 workspace + admin + sandbox 文件"
  - test "kb.db 空初始化可用"
  - test "首个 CR 创建 scope=全部"
  - test "重复创建同一租户 idempotent"
```

**前置**: A1-A4 (soul/skill/KB 模块就位), 测试需临时目录

**验收**: `mix test test/ezagent_plugin_content/tenant/` — 全部绿 (~10 tests)

---

### Task A6: ezagent_plugin_cr — CR 引擎

**产出**: `apps/ezagent_plugin_cr/` 完整 plugin + 单元测试

**参考设计**: §5 CR 发布流, §5.1-5.4

**模块接口定义**:

```elixir
# cr_engine.ex — CR 核心 (§5.1-5.3)
@type cr :: %{
  cr_id: String.t(), tenant_id: String.t(), status: :open | :published | :cancelled,
  target_kind: :soul_slot | :skill | :kb | :soul | :bundle,
  scope: [map()], scope_hash: map(), created_by: String.t(), created_at: DateTime.t(),
  published_version: String.t() | nil
}

@spec ensure_active_cr(tid :: String.t()) :: {:ok, cr()} | {:error, term()}
def ensure_active_cr(tid)
  # 查 ConfigStore 是否有 status=open 的 CR
  # 有 → 返回; 无 → 创建新的
  # key: cr:<tid>:<cr_id>  (cr_id = "cr-#{Date.now}-#{seq}")
  # 一个租户同时只有一个 active draft CR

@spec track_change(tid :: String.t(), resource :: {:soul_slot, role, section_id}
                                                   | {:skill, name}
                                                   | {:kb, :entry | :source, id}
                                                   | {:soul, role}
                                                   | {:config, key}) ::
        :ok | {:error, term()}
def track_change(tid, resource)
  # 1. ensure_active_cr(tid)
  # 2. 将 resource 加入 CR scope
  # 3. 更新 scope_hash (sha256 of sandbox resource content)
  # 如果 resource 已在 scope → 更新 hash; 不在 → 添加

@spec lock_scope(cr_id :: String.t()) :: :ok | {:error, term()}
def lock_scope(cr_id)
  # 冻结 scope_hash, 设 scope_locked_at + TTL (24h)
  # 锁期间 sandbox 对应资源不可编辑 (写操作返回 423 Locked)
  # 锁释放: Publish / Cancel / TTL 过期

@spec publish(cr_id :: String.t()) :: {:ok, version :: String.t()} | {:error, term()}
def publish(cr_id)
  # 1. Lint check (cr_lint.ex R01-R05)
  # 2. 确定版本号: 当前 _current → v<N>, 新版本 = v<N+1>
  # 3. ConfigStore: sandbox slot_values → release slot_values
  # 4. Filesystem: cp sandbox/ scope 内资源 → release/v<N+1>/
  # 5. ln -sf release/v<N+1> → _current
  # 6. PubSub broadcast {:content_published, tid, version}
  # 7. CR status → published

@spec cancel(cr_id :: String.t()) :: :ok | {:error, term()}
def cancel(cr_id)
  # 释放锁, CR status → cancelled
  # scope 内资源恢复可编辑

@spec rollback(tid :: String.t(), target_version :: String.t()) ::
        {:ok, version :: String.t()} | {:error, term()}
def rollback(tid, target_version)
  # ln -sf release/v<target> → _current
  # 新 agent 自动拿到旧版本内容

# cr_lint.ex — 引用检查 (§5.4)
@spec check(cr :: cr()) :: {:ok, [warning]} | {:error, [error]}
def check(cr)
  # R01 (error): scope 内资源引用了 release 不存在的 ID
  # R02 (warning): scope 内资源引用了 sandbox 有 diff 但不在 scope 的依赖
  # R03 (error): rename/delete 导致其他资源引用断裂
  # R04 (error): slot _template_version 与 release 模板不匹配
  # R05 (warning): L1/L2 资源 publish 时列出受影响租户

# cr_snapshot.ex — 快照管理 (§5.1)
@spec snapshot(tid :: String.t(), scope :: [map()]) :: :ok | {:error, term()}
def snapshot(tid, scope)
  # 按 scope 拷贝 sandbox → release/v<N>/
  # 只拷贝 scope 内资源, scope 外的不动
  # 非 scope 资源从上一个 release 版本继承 (hardlink, 节省空间)

# cr_rollback.ex — 回滚 (§5.1)
@spec list_versions(tid :: String.t()) :: [String.t()]
def list_versions(tid)
  # 列出 release/ 下所有 v<N> 目录, 按版本号降序
```

**CR 数据存储** (§5.1):

```
ConfigStore key: cr:<tid>:<cr_id>
body: yaml 格式 (同设计文档 §5.1 定义)

scope_hash 计算:
  ConfigStore 资源: sha256(JSON.encode(slot_values[section]))
  Filesystem 资源: sha256(File.read!(path))
```

**测试清单** (放在 `test/ezagent_plugin_cr/`):

```
cr_engine_test.exs:
  - test "ensure_active_cr 创建/复用"
  - test "track_change 添加 resource 到 scope"
  - test "lock_scope 冻结 scope_hash"
  - test "lock 期间 sandbox 编辑返回 423"
  - test "publish 拷贝 sandbox→release, 翻 _current"
  - test "publish 后 CR status → published"
  - test "cancel 释放锁"
  - test "rollback 翻 _current 到旧版本"
  - test "selective publish: 取消勾选的项留在 sandbox"

cr_lint_test.exs:
  - test "R01 引用不存在的 release ID → error"
  - test "R02 未发布依赖 → warning"
  - test "R03 rename 断裂 → error"
  - test "R04 模板版本不匹配 → error"

cr_snapshot_test.exs:
  - test "snapshot 只拷贝 scope 内, 其余 hardlink 继承"
  - test "rollback 正确列出历史版本"
```

**前置**: A1-A5 (content plugin 就位), 测试需临时 sandbox/release 目录

**验收**: `mix test test/ezagent_plugin_cr/` — 全部绿 (~18 tests)

---

### Task A7: CinnoxAssets/Runtime 重构 → content plugin

**产出**: autoservice plugin 改动，~4 文件

**参考设计**: §2.1 模块对照 (旧→新), §6.6.2 TenantContent 接口

**改动清单**:

```
apps/ezagent_plugin_autoservice/lib/ezagent_plugin_autoservice/
  customer_session.ex:
    重构 ensure_fast_agent/4:
      旧: system_prompt ← CinnoxAssets.build_fast_ack_prompt()
      新: system_prompt ← File.read!(TenantRuntime.path(tid, :release, ["config", "fast_ack_prompt.md"]))
      旧: @deepseek_api_url, @deepseek_model 硬编码
      新: 从 priv/skeleton/config/agents.yaml 读取 (Application.app_dir)
      旧: CinnoxAssets.default_soul_slot_values()
      新: SoulStore.defaults(tid, role)

    重构 maybe_slow_agent/4:
      旧: CinnoxRuntime.materialize_cinnox_cc!()
      新: TenantRuntime.materialize(tid, role, :release)
      旧: CinnoxAssets.build_cc_claude_md_with_slots(soul_slot_values)
      新: SoulRenderer.full_claude_md(tid, role, soul_slot_values)
      旧: CinnoxRuntime.kb_mcp_servers()
      新: KbMcpProvider.config(tid)

    租户参数化:
      所有 "cinnox" 字符串 → tid 参数
      ensure_fast_agent → 接受 tid 参数
      maybe_slow_agent → 接受 tid 参数
      fast_persona/0 → 删除(改从文件读)

  uris.ex:
    确认 URI 推导逻辑与 tenant_id 无关(纯函数, 不依赖具体租户名)
    session_uri → session://cs/<ws>/<customer_name>  (不变)
    fast_agent_uri → entity://agent/<ws>/fast-<customer_name>  (不变)

  ezagent.demo.seed_autoservice.ex:
    重构为 ezagent.tenant.seed.ex
    旧: 硬编码 cinnox tenant
    新: 接受 --tenant=<tid> --brand=<name> --industry=<industry>
    调用 TenantProvisioner.create_tenant(tid, brand, opts)

  application.ex:
    移除 CinnoxAssets/CinnoxRuntime 引用
    改为依赖 content plugin

  删除/标记 deprecated:
    cinnox_assets.ex → @deprecated "Use EzagentPluginContent.Soul.SoulRenderer"
    cinnox_runtime.ex → @deprecated "Use EzagentPluginContent.Tenant.TenantRuntime"
    kb_curator_agent.ex → 迁移到 content plugin, 原文件 @deprecated
```

**PR #715 发现整合**:
- #11 role-based 门控: `CLAUDE.md` preamble 用 role-based 代替 @mention-based (PR #715 已验证)
- #12 "AI 客服" label: `chat_ui.ex` label_for 匹配 system-principal + /agent/ sender

**测试清单**:

```
autoservice 现有测试:
  - customer_session_test.exs: 验证重构后 provisioning 仍正确
  - demo seed 测试: 验证 --tenant=cinnox 创建成功

新增测试:
  - customer_session 用 tid="test-tenant" 验证参数化
  - agents.yaml 读取验证
```

**前置**: A1-A6 全部完成

**验收**:
- `mix test apps/ezagent_plugin_autoservice/` — 现有测试全部绿
- `mix ezagent.tenant.seed --tenant=cinnox` — 创建成功

---

### Task A8: cinnox 数据迁移

**产出**: 一次性迁移脚本 `mix ezagent.content.migrate_cinnox`

**迁移清单**:

```
旧路径 (autoservice priv/cinnox/)          新路径 (runtime)
─────────────────────────────────────      ─────────────────────────
souls/customer_soul.md                 →   sandbox/souls/customer_soul.md
skills/customer/*/SKILL.md             →   sandbox/skills/customer/<name>/SKILL.md
  (包括 flow_chunks → 统一为 skill)        (flat .md, 统一命名)
kb/kb.db                               →   sandbox/kb/kb.db (直接 cp)
kb/glossary.json                       →   sandbox/kb/glossary.json
kb/escalation_keywords.json            →   sandbox/kb/escalation_keywords.json
kb/synonym-map.json                    →   sandbox/kb/synonym-map.json
kb/kb_search_mcp.py                    →   sandbox/kb/kb_search_mcp.py
kb/query_expansion.py                  →   sandbox/kb/query_expansion.py
references/*.yaml                      →   废弃, 内容归入 skill
fast-deepseek-prompt/prompts.py        →   sandbox/config/fast_ack_prompt.md (从 Python 转为 .md)
(无)                                   →   sandbox/slots/customer.yaml (从 CinnoxAssets.default_soul_slot_values() 生成)
```

**迁移脚本**:

```elixir
defmodule Mix.Tasks.Ezagent.Content.MigrateCinnox do
  @moduledoc """
  一次性迁移: autoservice priv/cinnox/ → runtime tenants/cinnox/

  幂等: 多次运行只复制缺失文件, 不覆盖已有
  """
  use Mix.Task

  def run(_args) do
    # 1. 创建 sandbox 目录结构
    # 2. cp soul, skills, kb
    # 3. 生成 slot_values.yaml (从旧 CinnoxAssets.default_soul_slot_values())
    # 4. 生成 fast_ack_prompt.md (从旧 prompts.py 提取)
    # 5. 调用 TenantProvisioner.create_tenant (workspace + admin)
    # 6. 创建首个 CR + Publish v1
  end
end
```

**验收**:
- 迁移后 `mix compile` 通过
- `TenantRuntime.path("cinnox", :sandbox, ["souls", "customer_soul.md"])` 文件存在
- `TenantProvisioner` 不报错 (workspace 已创建)
- agent provision 可用 cinnox 租户

---

## Phase B: autoservice 精简 + Turn 接入

### 目标

1. autoservice 精简为容器外壳
2. Customer 路径接入 Turn + CustomerFeed（PR #715 已验证可行，本 Phase 整合）
3. Operator 接管完善

### 前置条件
- Phase A 全部完成
- ezagent_domain_socialware (Turn, CustomerFeed) 可用

### Task B1: autoservice_assembly.ex — 组装协调

**产出**: autoservice plugin 新文件

**模块接口**:

```elixir
defmodule EzagentPluginAutoservice.AutserviceAssembly do
  @moduledoc """
  组装协调 — autoservice 唯一的胶水模块 (§2.3, §6.6.2)。

  不包含业务逻辑, 只做 wiring。
  """

  alias EzagentPluginContent.{Soul.SoulRenderer, Skill.SkillIndexer, Tenant.TenantRuntime}
  alias EzagentPluginContent.Kb.KbMcpProvider
  alias EzagentPluginCr.CrEngine

  @doc "生产 agent provision (§6.5, §6.6.2)"
  @spec provision_agent(tid :: String.t(), role :: String.t()) ::
          {:ok, %{fast_uri: URI.t(), slow_uri: URI.t(), session_uri: URI.t()}} | {:error, term()}
  def provision_agent(tid, role)
    # 1. TenantRuntime.materialize(tid, role, :release) → work_dir
    # 2. 读 agents.yaml → model, endpoint, max_tokens, thinking
    # 3. 创建 fast agent (curl.agent template, system_prompt ← release config)
    # 4. 创建 cc agent (cc flavor, cwd ← work_dir)
    # 5. 创建 session (session://cs/<ws>/<customer>)
    # 6. 安装 routing
    # 7. 返回 agent + session URI

  @doc "Admin sandbox 预览 (§8 admin preview 隔离规则)"
  @spec preview_provision(tid :: String.t(), role :: String.t(), admin_uri :: URI.t()) ::
          {:ok, %{session_uri: URI.t(), fast_uri: URI.t(), cc_uri: URI.t()}} | {:error, term()}
  def preview_provision(tid, role, admin_uri)
    # 与 provision_agent 相同, 但:
    #   数据源 = sandbox (TenantRuntime.materialize(tid, role, :sandbox))
    #   session = session://preview/<tid>/<role>-<timestamp>
    #   agent URI 带 -preview-<admin>-<timestamp>

  @doc "预览结束清理"
  @spec preview_teardown(session_uri :: URI.t()) :: :ok
  def preview_teardown(session_uri)
    # SpawnRegistry.terminate(fast_uri) + SpawnRegistry.terminate(cc_uri)
    # RuleStore.delete(preview routing rule)
    # Session.destroy(session_uri)
    # File.rm_rf(preview work dir)

  @doc "Admin 编辑 slot → 写 sandbox + 跟踪 CR (§8.2, §5.3)"
  @spec write_slot(tid :: String.t(), role :: String.t(), key :: String.t(), val :: String.t()) :: :ok
  def write_slot(tid, role, key, val)
    # SoulStore.write_slots(tid, role, %{key => val}) → 写 sandbox
    # CrEngine.track_change(tid, {:soul_slot, role, section_id})
end
```

**测试**:
- provision_agent 调用链正确 (mock content plugin)
- preview_provision 使用 sandbox 数据源
- write_slot 触发 track_change

**前置**: Phase A 完成

---

### Task B2: Turn 接入 (Customer 路径)

**产出**: `turn_adapter.ex` + `customer_session.ex` 改动 + `customer_live.ex` 改动

**参考设计**: §6.1-6.2, §6.6.1 TurnAdapter 接口

```elixir
defmodule EzagentPluginAutoservice.TurnAdapter do
  @moduledoc "Turn 编排 — 内部通过 Router.dispatch 调 socialware Turn Behavior (§6.6.1)"

  alias Ezagent.{Router, Cmd}

  def open_turn(session_uri, %{customer_uri: customer_uri, text: text}) do
    Router.dispatch(%Cmd{
      target: session_uri, action: :turn.open,
      args: %{trigger: %{msg: text, from: customer_uri}, opened_at: System.system_time(:second)},
      ctx: system_ctx()
    })
  end

  def compose_turn(session_uri, turn_id, %{agent_uri: agent_uri, text: text}) do
    Router.dispatch(%Cmd{
      target: session_uri, action: :turn.compose,
      args: %{turn_id: turn_id, result_refs: [%{agent: agent_uri, text: text}]},
      ctx: system_ctx()
    })
  end

  def settle_turn(session_uri, turn_id) do
    Router.dispatch(%Cmd{
      target: session_uri, action: :turn.settle,
      args: %{turn_id: turn_id}, ctx: system_ctx()
    })
  end

  def claim_turn(session_uri, turn_id, %{operator_uri: op}) do
    Router.dispatch(%Cmd{
      target: session_uri, action: :turn.claim,
      args: %{turn_id: turn_id, by: op}, ctx: system_ctx()
    })
  end
end
```

**customer_live.ex 消息流** (§6.1, PR #715 #10):

```
客户发消息:
  → TurnAdapter.open_turn(session_uri, %{customer_uri, text})  ← 先 open
  → fast agent ACK (deepseek 即时安抚)
  → cc agent 主回复 + kb_search + skill Read
  → TurnAdapter.compose_turn(session_uri, turn_id, %{agent_uri, text})
  → TurnAdapter.settle_turn(session_uri, turn_id)
  → CustomerFeed.deliver → loom/customer_live 收到

客户消息回显 (PR #715 #10):
  客户消息是 Turn trigger, 不是 settled message
  → CustomerFeed 不返回 (正确行为 — 门控只投递 settled 消息)
  → customer_live 本地乐观回显: 发送后立即 append 到 messages 列表
  → 与 CustomerFeed 收到的消息按时间 merge
```

**PR #715 发现整合**:

| # | 发现 | 整合到本 Task |
|---|---|---|
| #10 | 客户消息乐观回显 | customer_live.ex — 本地 append + merge |
| #11 | role-based 门控 | CLAUDE.md preamble — "仅回复 @mention" → "回复客户消息, 对自己+operator 沉默" |
| #12 | "AI 客服" label | chat_ui.ex — label_for 匹配 system-principal + /agent/ sender |

**测试**:
- Turn lifecycle 集成测试: open → compose → settle
- customer_live 消息流: 客户消息 → agent 回复 → UI 显示
- 客户消息回显: settle 后 customer 看到自己的消息 + bot 回复

**前置**: B1 (assembly 就位)

---

### Task B3: Operator 接管完善

**产出**: `operator_live.ex` 改动

**参考设计**: §7 Operator 接管

```
接管流程 (§7.1):
  operator 选择 session → TurnAdapter.claim_turn(session_uri, turn_id, %{operator_uri})
    → visibility: :customer_visible → :operator_only
    → RuleStore.disable(rule_id)  ← 暂停 agent route
    → PubSub.broadcast(session_topic, {:operator_joined, operator_uri})

  operator 编辑消息 → 预览 (不投递 customer)

  operator 提交 → TurnAdapter.settle_turn(session_uri, turn_id)
    → visibility: :operator_only → :customer_visible
    → CustomerFeed.deliver
    → RuleStore.enable(rule_id)  ← 恢复 agent route
    → PubSub.broadcast(session_topic, {:operator_settled, operator_uri})
```

**Route 调整** (§7.2):
- 用已有 `RuleStore.disable/1` + `RuleStore.enable/1` (零 core 改动)
- RuleStore.list(@routing_table) |> Enum.find(matcher) → rule.id → disable/enable

**测试**:
- 接管流程集成测试: claim → operator 编辑 → settle → customer 看到
- visibility 门控: 接管期间 customer 看不到草稿

**前置**: B2 (Turn 接入)

---

### Task B4: CustomerFeed 订阅替换 session_events_topic

**产出**: `customer_live.ex` + `operator_live.ex` 改动

**参考设计**: §6.3 CustomerFeed 门控

```
替换:
  旧: Phoenix.PubSub.subscribe(EzagentCore.PubSub, Chat.session_events_topic(session_uri))
  新: subscribe to CustomerFeed.topic(session_uri)

CustomerFeed 行为:
  - settle 后才投递消息 (门控)
  - visibility: customer_visible | operator_only
  - loom/customer_live 只收到 customer_visible + settled 消息
  - operator_live 收到全部消息 (含 operator_only)
```

**测试**:
- customer 只收到 settle 后的消息
- operator 接管期间 customer 看不到草稿
- customer 自己的消息通过本地回显 (不通过 CustomerFeed)

**前置**: B2, B3

---

## Phase C: Admin UI 补齐

### 目标
Master Admin 和 Tenant Admin 完整管理界面。

### 前置条件
- Phase A + Phase B 完成 (content, cr, autoservice 后端功能就位)

### Task C1: Master Admin 页面

**产出**: liveview plugin 3 新文件

```
master_dashboard_live.ex:
  列表展示: 租户数, 活跃租户, 总 CR 数, 最近发布
  租户列表: 每个租户的当前版本, active CR 数, [进入] 链接
  数据源: Content.Tenant.TenantConfig (list all) + CR plugin (count active)

tenant_onboard_live.ex:
  Step 1: 基本信息 (tenant_id, brand_name, industry, role)
  Step 2: Admin 账号 (handle, password)
  Step 3: 初始化 → 调 autoservice.assembly.provision_tenant → sandbox ready
  完成后: 重定向到 tenant_dashboard

platform_content_live.ex:
  L0/L1/L2 soul 模板编辑 (代码编辑器)
  平台 skill 模板编辑
  保存 → 写 priv/platform/ (走 git)
```

**验收**: master admin 可创建租户, 编辑平台模板

### Task C2: Tenant Admin 页面

**产出**: liveview plugin 5 新文件

```
tenant_dashboard_live.ex:
  当前版本, Active CRs, 悬挂改动 (不在任何 CR 的 sandbox diff)
  [预览 sandbox] → 调 autoservice.assembly.preview_provision → 打开 preview LiveView
  [查看版本历史] → 列出 release/ 下所有版本
  [进入 CR] → cr_dashboard_live

skill_editor_live.ex:
  4 层 tab 切换 (Tenant / Industry / Platform / Framework)
  文件列表 → 点击编辑 → 代码编辑器
  创建新 Skill → 输入 name + content → 写 sandbox
  保存 → SkillStore.write → CrEngine.track_change

kb_manager_live.ex:
  搜索框 → KbStore.search
  URL 抓取: 输入 URL → KbStore.fetch_url
  文件上传: 拖拽/选择文件 → KbStore.ingest_file
  条目编辑: 增删改 → KbStore.upsert/delete
  Escalation keywords: JSON 编辑器
  kb.db 重建: 按钮 → KbRebuilder.rebuild
  _sources 管理: 列表 + friendly_name 编辑

cr_dashboard_live.ex:
  CR 列表: active + published + cancelled
  CR 详情: scope 清单 (每项可勾选/取消), scope_hash, diff 视图
  [Publish 选中] → CrEngine.publish
  [Cancel] → CrEngine.cancel

operators_live.ex:
  当前租户 operator 列表
  添加: WorkspaceUserAdmin.create_user → 授予 operator caps
  禁用: 移除 operator caps
```

**验收**: tenant admin 可完整管理 soul/skill/KB/CR/operator

---

## Phase D: FillerLoop + 优化（可 defer）

### Task D1: FillerLoop

**产出**: `filler_loop.ex` (loom 或 autoservice plugin)

```
FillerLoop 协程:
  cc_phase 启动时 spawn
  每 N 秒 (text 10s / voice 4s) → deepseek 生成安抚填充语
  最多 3 次
  cc 完成或超时 → 停止

cc 超时处理:
  45s 硬超时 → emit 静态道歉 (从 config 读)
  persist source=cc_timeout → MessageStore
```

### Task D2: 其他优化

- deepseek 连续失败 3 次 → 熔断, 会话永久 pin 回静态 fallback
- agent 预热 (prewarm): server 启动时预创建 cc agent, 减少首消息延迟
- live finding: effort=low 默认, 验证 ~26s 延迟

---

## 风险与缓解

| 风险 | 影响 | 缓解 |
|---|---|---|
| Python MCP 依赖 (uv, kb_search_mcp.py) | A4 KB rebuild 失败 | CI 预装 uv, test mock Python call |
| content + cr plugin 循环依赖 | 编译失败 | content 不依赖 cr; cr 依赖 content 是单向的 |
| cinnox 数据迁移失败 | 旧 demo 不可用 | 迁移脚本幂等, 多次运行不覆盖已有 |
| Turn 状态机集成复杂 | Phase B 阻塞 | PR #715 已验证可行, 本 Phase 整合而非重写 |
| loom 不在 autoservice 分支 | Customer 路径缺前端 | Phase B 用 CustomerLive 验证, loom 后续对接 |

---

## 测试策略

```
Phase A:
  content plugin → 独立 ExUnit (mock 外部依赖: Python, ConfigStore)
  cr plugin → 独立 ExUnit (mock content plugin 读 sandbox)
  A7 重构 → autoservice 现有测试必须全绿 (回归保护)
  A8 迁移 → 集成测试: 迁移后 agent provision 可用

Phase B:
  TurnAdapter → 单元测试 (mock Router)
  assembly → 集成测试 (mock content + cr)
  customer/operator LiveView → agent-browser E2E (真实 cc agent)

Phase C:
  LiveView → 单元测试 (mock backend)
  E2E: admin 创建租户 → 编辑 soul → preview → CR publish → customer 聊天
```

---

## 文件统计

```
Phase A:
  ezagent_plugin_content:  18 新文件 (lib + test + priv)
  ezagent_plugin_cr:        5 新文件 (lib + test)
  autoservice:              ~4 改动 (重构)
  A8 迁移脚本:              1 新文件
Phase B:
  autoservice:              ~6 改动 (assembly + turn + operator + customer)
Phase C:
  liveview:                 ~8 新文件 (master + tenant admin)
Phase D:
  loom/autoservice:         ~2 新文件
─────────────────────────────────
合计: 2 新 plugin, ~44 文件
core: 0 / domain: 0
```

---

*配套设计: [`2026-06-10-autoservice-v2-design.md`](../specs/2026-06-10-autoservice-v2-design.md)*
*PR #715 Stage-1 live findings 已整合到 Phase B (Turn, role-based gate, customer echo, AI label)*
