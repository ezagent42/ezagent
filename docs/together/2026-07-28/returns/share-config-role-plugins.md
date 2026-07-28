> **Task:** share-config — role_plugins / socialware_check_reference_apps 挪 config.exs
> **Branch:** `feat/socialware-share-config`
> **PR:** https://github.com/ezagent42/ezagent/pull/1612
> **Dev:** jjkysy (agent)
> **returned_at:** 2026-07-28 18:20 +0800
> **deadline:** 2026-07-28 (Group A 推进)
> **deadline_status:** on_time

## 做了什么
URI-share Group A 的 **config 件**(handoff §7.7「决定 2」):把两个通用 CLI 任务里**硬编码的插件 app 列表**从模块 `@attribute` 挪进 `config.exs`,让部署可扩展、且通用 infra 任务不焊死具体插件。非破坏(默认完全保留原值)。

- `config/config.exs` 加两键:
  - `config :ezagent_domain_agent, role_plugins: [:ezagent_plugin_kanban]`
  - `config :ezagent_domain_session, socialware_check_reference_apps: [:ezagent_domain_socialware, :ezagent_plugin_hello, :ezagent_plugin_kanban]`
- `mix ezagent.agent.grant_recipe_caps`(domain_agent):`@role_plugins` 属性 → `@default_role_plugins` + 私有 `role_plugins/0` 读 `Application.get_env(:ezagent_domain_agent, :role_plugins, @default_role_plugins)`。
- `mix ezagent.socialware.check`(domain_session):`@reference_apps` → `@default_reference_apps` + 私有 `reference_apps/0` 读 config,同款。

## 关键决策
- **默认保留原值**:两个 `@default_*` 属性 = 之前硬编码的确切列表,`get_env` 第三参回落它——无 config 时行为**逐字不变**,纯 additive。
- **为什么挪**:`grant_recipe_caps` 是通用 task,`@role_plugins [:ezagent_plugin_kanban]` 焊死 kanban、漏了 cc/py/其它 role-owning 插件;挪 config 后部署加插件不用改 infra 代码(去 kanban⇄infra 泄漏,skill-1 债③)。
- **不碰测试侧的 `ensure_manifest_reference_apps_started`**(world_conversation_test.exs):那是测试自有的 setup helper,不在本 config 迁移范围。

## DoD reconciliation
| # | DoD line | status | proof |
|---|----------|--------|-------|
| 1 | 两 task 从 config 读列表,非 @attribute | met | grant_recipe_caps `role_plugins/0` + socialware.check `reference_apps/0` |
| 2 | config.exs 有两键,默认=原硬编码值 | met | `mix run` 实证:role_plugins=[:ezagent_plugin_kanban] · reference_apps=[..socialware,hello,kanban] |
| 3 | 两 app 编译 0 error/warning | met | domain_agent + domain_session Generated,无 warning |
| 4 | 非破坏(默认行为逐字不变) | met | @default_* = 原属性值,get_env 回落 |
| 5 | format clean | met | 3 文件 check-formatted 过 |
| 6 | full suite CI 绿 + Loop C | pending | push 后 CI run |

**Method friction:** fresh worktree deps 含 heroicons git dep 沙箱 fetch 失败 → 从姊妹 worktree `cp -rn deps/.` 绕过(同前几件)。mix task 无单测入口 → 用 `mix run` 直接查 `Application.get_env` 返回值验证 config 生效。

## 分支 + gate 状态
- Branch off `origin/main` @ `9da88c162`,独立。
- 本地:两 app 编译 clean + config 读取实证 + format clean。CI:push 后 run URL。

## Merge request
Group A 独立件(与 A1/A2-1/A2-2/A3/A4-1 并行,互不依赖)。建议 lead 待 CI 绿后并入 main。
