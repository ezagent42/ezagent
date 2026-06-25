# Core 改动说明：`@callback config_schema/0` 新增

> 写给团队（allenwoods、zyli-developer、zhaomaota97）。gagameow（黄佳佳），2026-06-25。
> 上下文：agent console 任务 B，M2 里程碑。

---

## 改什么

**文件**：`apps/ezagent_core/lib/ezagent/kind/template.ex`

**改动**：+2 行。

```diff
+ @callback config_schema() :: [map()]
```

```diff
  @optional_callbacks [
    ...
+   config_schema: 0,
    ...
  ]
```

## 为什么

### 背景

当前 agent console 需要按 flavor 展示 agent 的配置字段。问题是：**不同 flavor 有完全不同的配置字段**。

| Flavor | 配置字段 |
|---|---|
| cc | `model`, `effort`, `permission_mode`, `allowed_tools`, `disallowed_tools`, `mcp_servers`, `system_prompt`, `soul_md` |
| codex | `model`, `approval_policy`, `sandbox`, `soul_md` |
| curl | `model`, `provider`, `api_url`, `system_prompt` |
| echo | 无 |

前端（React）不能硬编码一份"统一字段列表"——硬编码了 cc 的字段，codex 页面上就会出现无意义的 effort/permission_mode；反过来写了 codex 的字段，cc 页面就会缺 model 选项。

### 解决方案

让**后端**告知前端每个 flavor 有哪些字段、每个字段是什么类型、有哪些可选值。

这个知识应该在哪？Template Class 已经通过以下回调掌握了这个知识：

- `template_data_extra/1` — 返回模板扩展字段（如 cc 的 `model`/`effort`）
- `validate/1` — 校验模板字段合法性
- `sdk_sidecar_params/2` — 消费字段传给 sidecar

`config_schema/0` 只是把这份**已有知识显式化声明出来**，不是发明新东西。

### 为什么是 `Kind.Template`

按 P12（Adapter pattern）——flavor-specific 的知识必须在 plugin 层，不能放 core。

- Template Class 已经在 `ezagent_plugin_cc` / `ezagent_plugin_codex` 里
- 通过现有链路 `AgentFlavorRegistry.lookup(flavor) → template_class` 就能拿到 schema
- 不需要新注册表、不增加 core 的依赖

### 为什么是 `@optional_callback`

和现有的 8 个 optional callback 相同模式：
- 不实现的 Template Class（echo 等）→ 默认返回 `nil`/`[]`
- 完全向前兼容，不破坏任何现有行为
- 不影响未提交的 PR、不需要 migration

### 为什么不是别的方式

| 方案 | 为什么不选 |
|---|---|
| 扩展 `Plugin.config_surface/0` | V1 只支持 `:route \| :flavor \| nil`，`kind: :form` 被显式拒绝。且 `config_surface` 是 plugin 级别（UI 导航），不是 flavor 级别（字段 schema）——两个不同关注点 |
| 新增注册表 `FlavorConfigSchema` | 多一层抽象。Template Class 已经有字段知识，加注册表 = 重复声明同一份知识到两个地方，容易漂移 |
| 前端硬编码字段列表 | 无法覆盖多 flavor。cc 有 effort、codex 没有 — 硬编码一定错 |

## 影响面

| 维度 | 状态 |
|---|---|
| **core LOC** | +2 行（template.ex 当前 500+ 行） |
| **破坏性变更** | 无。optional callback，不实现不影响 |
| **依赖新 callback 的逻辑** | 无。core 不调 `config_schema/0`，只在 plugin 层和 world:state 数据流中消费 |
| **CI gate** | 不影响 `mix check_invariants`。`plugin_contract_test` 已覆盖 Template Class 的 optional callback 模式 |

## 后续

1. cc/codex/cc-headless/codex-remote 各实现 `config_schema/0`（每文件 ~10 行）
2. `identity_data.ex` 中通过 `AgentFlavorRegistry.lookup(flavor) → template_class.config_schema()` 读取 → 放入 `world:state` JSON
3. 前端按 schema 渲染结构化编辑器（M3）、创建表单（M4）

## 讨论

如果需要讨论或 block，请在 PR 中 comment 或 Feishu 找我（gagameow）。
