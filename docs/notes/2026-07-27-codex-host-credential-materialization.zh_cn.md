# Codex 宿主凭据 materialization 失败（2026-07-27）

## 现象

宿主机存在有效的 `~/.codex/auth.json`，但 Hello 使用
`llm_flavor: "codex"` 创建角色时，在页面生成前失败：

```text
{:agent_spawn_failed, "llm",
 {:codex_app_server_not_ready,
  {:codex_app_server_exited_before_ready, "/.../codex/<agent>/app-server.sock", ""}}}
```

每个 agent 的独立 `CODEX_HOME` 被创建后没有 `auth.json`，因此 Codex
app-server 在 PTY/TUI 启动前退出。

## 证据

- `/home/lenovo/.codex/auth.json` 存在，权限为 `0600`，JSON 有效并包含
  Codex 登录元数据。
- `Ezagent.Credential.HomeRuntime.host_login_dir("CODEX_HOME", ".codex")`
  解析为 `/home/lenovo/.codex`。
- workspace 默认凭据源已登记为
  `entity://system/agent/codex-host-login`。
- 多次 Codex Hello materialize 尝试后，分配的 agent 目录仍没有
  `auth.json`，并在 `CodexAgent.ensure_app_server/…` 阶段失败。
- 使用 curl flavor 的 Hello 流程不受影响，页面生成成功。
- 重新分别测试 `llm_flavor: "codex"` 与 `llm_flavor: "codex-remote"`，两者都在
  app-server readiness 阶段失败；remote flavor 使用了自己的 socket，但同样
  没有 materialize 出 `auth.json`。

## 当前判断

宿主登录本身没有问题；宿主登录源登记、凭据级联和 Codex sidecar 启动
之间没有在启动前收敛。问题位于凭据源 materialization/授权链路，而不是
Hello 页面生成器。

## 复现

```elixir
EzagentPluginHello.App.ensure_app("system", "codex-e2e", llm_flavor: "codex")
```

预期是 llm 角色携带完整 Codex home 并生成 Hello 页面；实际得到
`codex_app_server_exited_before_ready`。

## 下一步

跟踪 `Ezagent.Credential.HomeRuntime.create_agent_config_dir_with_grant/4`
经过 source resolution、grant verification 和 `stage_and_swap/7` 的完整路径；
增加集成回归测试，确保调用 `AppServer.start/2` 前分配的 Codex home 已包含
`auth.json`。
