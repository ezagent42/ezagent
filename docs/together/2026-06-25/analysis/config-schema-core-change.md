# Core 改动说明：`@callback config_schema/0` + `@type config_field` 新增

> 写给团队（allenwoods、zyli-developer、zhaomaota97）。gagameow（黄佳佳），2026-06-25。
> 上下文：agent console 任务 B，M2 里程碑。经两轮 codex review 确认。

---

## 改什么

**文件**：`apps/ezagent_core/lib/ezagent/kind/template.ex`

**改动**：+~20 行（Shape 定义 ~15 行 + Callback ~2 行 + optional_callbacks ~1 行）。

```elixir
# 新增：config field 类型定义（一次性。后续加字段类型才动这里）
@type config_field_type :: :string | :enum | :list | :json | :text | :boolean

@type config_field :: %{
  required(:key) => String.t(),
  required(:type) => config_field_type(),
  optional(:options) => [String.t()],
  optional(:editable) => boolean(),
  optional(:source) => :template | :cascade
}

# 新增：optional callback
@callback config_schema() :: [config_field()]
```

在 `@optional_callbacks` 列表末尾加 `config_schema: 0`。

---

## 为什么

### 背景

当前 agent console 需要按 flavor 展示 agent 的配置字段。问题是：**不同 flavor 有完全不同的配置字段**。

| Flavor | 配置字段 |
|---|---|
| cc | `model`, `effort`, `permission_mode`, `allowed_tools`, `disallowed_tools`, `mcp_servers`, `system_prompt`, `soul_md` |
| codex | `model`, `approval_policy`, `sandbox`, `soul_md` |
| curl | `model`, `provider`, `api_url`, `system_prompt` |
| echo | 无 |

前端（React）不能硬编码一份统一字段列表——cc 有 effort 但 codex 没有，硬编码一定错。

### 核心设计：Shape 在 core，Data 在 plugin

关键洞察：**变的是 data（model 列表），不是 shape（字段类型枚举）**。

| 层 | 内容 | 位置 | 变化频率 |
|---|---|---|---|
| **Shape** | `config_field` 类型定义 | core `kind/template.ex` | **极低**——只在加新字段类型时变 |
| **Data** | model 列表、effort 级别 | plugin Template Class | **高**——每次出新 model 就变 |

core 定义 shape 是一次性的。plugin 的 model 列表可通过 `Application.get_env` 覆盖——**不改代码也能加新 model**：

```elixir
# cc_agent.ex
@default_models ["deepseek-chat", "deepseek-v4-pro", ...]

def config_schema do
  models = Application.get_env(:ezagent_plugin_cc, :models, @default_models)
  [%{key: "model", type: :enum, options: models, ...}, ...]
end
```

部署时只需在 `config/runtime.exs` 加一行 `config :ezagent_plugin_cc, :models, [...]`，不需要重新编译 plugin。

---

## 为什么是 `Kind.Template`

按 P12（Adapter pattern）——flavor-specific 的知识必须在 plugin 层。

Template Class 已经通过以下回调掌握了配置字段的知识：

- `template_data_extra/1` — 返回模板扩展字段
- `validate/1` — 校验字段合法性
- `sdk_sidecar_params/2` — 消费字段传给 sidecar

`config_schema/0` 只是把这份**已有知识显式化声明出来**，不发明新东西。发现路径通过已有链路：

```
AgentFlavorRegistry.list_all → %{template_class: tc} → tc.config_schema()
```

不需要新注册表。

---

## 为什么不是别的方式

| 方案 | 为什么不选 |
|---|---|
| **放在 `agent_flavor_decl` 里**（`Plugin.agent_flavors/0` 返回值的 optional 字段） | `agent_flavor_decl` 保存的是**布线引用**（`template_class` 是 module atom、`bridge_adapter` 是 module atom），不是 UI schema。把嵌套数组结构（字段列表 + 选项列表）塞进 ETS 行，违反 declaration / wiring / UI 的分离。且每次改 model 列表都要重建 ETS 行（codex review 确认） |
| 扩展 `Plugin.config_surface/0` | V1 只支持 `:route \| :flavor \| nil`，`kind: :form` 被显式拒绝。且 `config_surface` 是 per-plugin 的 UI 路由，cc + cc-headless 同属一个 plugin 但字段不同——粒度对不上 |
| 新增注册表 `FlavorConfigSchema` | 多一层抽象。Template Class 已经有字段知识，加注册表 = 重复声明同一份知识到两个地方，容易漂移 |
| 前端硬编码字段列表 | 无法覆盖多 flavor。cc 有 effort、codex 没有——硬编码一定错 |

---

## 为什么是 `@optional_callback`

和现有的 10 个 optional callback（`validate`、`compile`、`template_data_extra`、`config_dir_namespace`、`list_extensions`、`toggle_extension`、`destroy_config_dir`、`ensure_subprocess_alive` 等）相同模式：

- 不实现的 Template Class（echo 等）→ 默认返回 `nil`/`[]`
- 完全向前兼容，不破坏任何现有行为
- 不需要 migration

---

## 影响面

| 维度 | 状态 |
|---|---|
| **core LOC** | +~20 行（template.ex 当前 500+ 行）。Shape 定义一次性，后续只改 plugin |
| **破坏性变更** | 无。optional callback，不实现不影响 |
| **依赖新 callback 的逻辑** | 无。core 不调 `config_schema/0`，只在 plugin 层和 world:state 数据流中消费 |
| **CI gate** | 不影响 `mix check_invariants`。`plugin_contract_test` 已覆盖 Template Class 的 optional callback 模式 |
| **改 model 列表** | 不改 core。改 plugin `application.ex` 或 `config/runtime.exs` 的 `Application.get_env` 即可 |

## 后续

1. cc / cc-headless / codex / codex-remote 各实现 `config_schema/0`（每文件 ~15 行）
2. `identity_data.ex` 中通过 `AgentFlavorRegistry.list_all → tc.config_schema()` 读取 → 放入 `world:state` JSON
3. 前端按 schema 渲染结构化编辑器（M3）、创建表单（M4）

## 讨论

如需讨论或 block，请在 PR 中 comment 或 Feishu 找我（gagameow）。
