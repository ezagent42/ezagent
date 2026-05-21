# Domain.Pty 架构 — PTY 提升到 Domain 层

> **状态**: DRAFT — 2026-05-21。作者: Claude（V1 验收期，按 Allen
> Feishu 2026-05-21 17:16 指示"Domain.Pty 提供统一 terminal UI page
> 这个需要讨论"）。等 Allen review 后实施。

## 0. 为什么

Allen V1 验收 Q4（Feishu 17:16）:

> 这样想起来，其实应该有一个独立的页面（类似admin setting那样）用于
> 提供Pty terminal界面，且这个界面应该是Domain.Pty提供的，目前有吗？
> 还是这是cc plugin自己实现的？其它使用了pty功能的agent（包括使用pty
> 执行或者erlexec执行的程序，echo agent等）也应该免费获得打开terminal
> 查看的能力，请audit并规划如何加入

当前 PTY 100% 归属 `EzagentPluginCc`:
- `Ezagent.PluginCc.PtyServer` — 封装 `:exec.run/2` (erlexec) 的 GenServer
- `Ezagent.Behavior.Pty` — Agent Kind 上的 `:write` action Behavior
- `EzagentPluginCc.Views.PtyView` — xterm.js Session View
- `EzagentPluginCc.PtyServerSupervisor` + `PtyServerRegistry`

结果: 未来任何想用本地 PTY 的 plugin（跑 `bash` 的 echo agent、测试
脚本的 curl-runner、通用 "shell agent"）只能选择:

1. 重新实现整个 erlexec wrapper + xterm.js view + supervision tree，或
2. 依赖 `ezagent_plugin_cc`（违反 `feedback_north_star_plugin_isolation`
   的 plugin 隔离原则）

**Allen 的 V2 macro 草图**已经命名好了正确归宿 ——
`Ezagent.Domain.Pty.PtyServer`（见 `docs/futures/v2-feedback-log.md`
"V2 macro charter"）。本 SPEC **现在**就把 PTY 从 cc plugin 提出来到
Domain 层，这样 V1 立即受益（echo agent 免费拿到 terminal-viewing），
V2 macro 工作不用中途搬代码。

## 1. 目标

1. **PTY runtime 提升**（PtyServer + Supervisor + Registry + Behavior）
   从 `ezagent_plugin_cc` 到新建的 `ezagent_domain_pty` 应用，
   Domain 层 (Tier-2 per ezagent-developer skill)。
2. **PTY UI 提升** — terminal view + xterm.js hook + 独立
   `/terminal/:agent_uri` 页 — 到 `ezagent_domain_ui` (Tier-2)，
   任何 LV 都能嵌入。
3. **跨 flavor 可选加入** — 任何 Agent Kind，其 template 声明
   `spawns_with: [Ezagent.Domain.Pty.PtyServer]` 自动获得:
   - agent boot 时 PTY 进程启动
   - Sessions 页 view-switcher 里的 Terminal view
   - per-agent `/terminal/:agent_uri` 独立页
   - `Ezagent.Domain.Agent.lifecycle_status/1` 报 PTY phase
4. **cc plugin 收缩**到只剩 cc-specific 部分:
   - `EzagentPluginCc.Channel`（claude TUI WS bridge）
   - `EzagentPluginCc.McpConfigWriter`（spawn claude 时写 `.mcp.json`）
   - `EzagentPluginCc.TokenStore`（CC bridge auth）
   - `Ezagent.PluginCc.Template.CcAgent`（template class — 用 Domain.Pty + cc 专属东西）

## 2. 非目标

- **不引入 PTY 自己的 top-level URI scheme**（invariant 11）。PTY 是
  关联 Agent URI 的 sidecar 进程，不该有自己的 scheme。
  `entity://agent/<flavor>/<workspace>/<name>?action=pty.write` 是
  dispatch contract（SPEC v2 §5.7 已经定义）。
- **不抽象 PTY backend** — `Ezagent.Domain.Pty.PtyServer` 硬编 erlexec。
  以后想要 native `Port.open(:spawn)` 或 remote PTY proxy 是 V2+ 的
  pluggable adapter 模式。
- **不要 back-compat shim** — 一旦搬完，引用
  `Ezagent.PluginCc.PtyServer` 编译错误。import 它的 plugin 必须
  更新到 `Ezagent.Domain.Pty.PtyServer`。
- **不要 cc 专属新功能**。cc plugin 完全拥有 MCP config + channel
  bridge + token store —— 这些是 CC 专属（claude TUI ↔ ezagent WS
  连接），不是 generic PTY。
- **不要 V2 macro**（按 v2-feedback-log charter）。macro 消费 Domain.Pty
  作为一个 step；本 SPEC 把 Domain.Pty 发出去，V2 才有东西包装。

## 3. 模块迁移地图

### 3.1 新 app: `apps/ezagent_domain_pty/`

标准 umbrella app 布局。依赖: 只有 `:ezagent_core`（Tier-2 规则；
不依赖 plugin、不依赖其它 domain）。

```
apps/ezagent_domain_pty/
├── lib/
│   ├── ezagent_domain_pty.ex                  # facade
│   ├── ezagent_domain_pty/
│   │   ├── application.ex                     # supervisor + registry
│   │   ├── server.ex                          # PtyServer（搬 + 改名）
│   │   ├── supervisor.ex                      # DynamicSupervisor for PTY processes
│   │   └── registry.ex                        # :via Registry by agent_uri
│   ├── ezagent/
│   │   ├── behavior/pty.ex                    # `:write` Behavior（原封不动搬）
│   │   └── domain/pty.ex                      # facade: start/2, stop/1, status/1
└── test/
    └── ... (测试搬过来)
```

模块重命名:
- `Ezagent.PluginCc.PtyServer` → `Ezagent.Domain.Pty.Server`
- `EzagentPluginCc.PtyServerSupervisor` → `EzagentDomainPty.Supervisor`
- `EzagentPluginCc.PtyServerRegistry` → `EzagentDomainPty.Registry`
- `Ezagent.Behavior.Pty` → 不变（已经是 Agent Kind 上的 behavior；只是换 app）

### 3.2 新 UI: `apps/ezagent_domain_ui/lib/ezagent_domain_ui/pty/`

Terminal view + xterm.js hook 搬到 Domain UI 层:

```
apps/ezagent_domain_ui/lib/ezagent_domain_ui/
├── pty/
│   ├── terminal_view.ex                       # SessionView（PtyView 改名）
│   └── terminal.ex                            # Phoenix.Component
└── ...

apps/ezagent_web/assets/js/hooks/
└── pty_terminal.js                            # xterm.js hook（原封搬）
```

`EzagentDomainUi.Pty.TerminalView` 注册成 SessionView（任何 session
里有 Agent member 其 template 声明了 PTY 的都会出现）。

### 3.3 新 LV: `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/terminal_live.ex`

Allen 想要的独立 "Terminal 页"。URL:
`/identities/agents/:uri/terminal`。

**路径形态说明 (Allen review 2026-05-21 15:13)**: 原 draft 用
`/terminal/:agent_uri`（动词在前）。违反代码库 resource-first URL
约定。Phase 8b 实际上**曾经有** `/identities/agents/:uri/terminal`，
后来为 SessionView-only 模式而废弃；V1 把独立页面带回，**用同样的
URL 形态**。LV-URL ↔ URI-system 映射约定见 **§13**。

```elixir
defmodule EzagentPluginLiveview.TerminalLive do
  @moduledoc """
  独立 PTY terminal 页面，给任何 template 在 spawns_with 里声明 PTY
  的 agent。URL: /terminal/<encoded-agent-uri>。

  渲染在 IdeShell（完整 workspace 表面），operator 有导航上下文。
  terminal 占主窗口；Members + Floating Agents 侧栏保留。

  按 Ezagent.Domain.Agent.lifecycle_status/1:
  - phase: :alive + 有 PTY detail → 渲染 terminal
  - phase: :registered（无 PtyServer alive）→ 渲染 "Not yet started" CTA
  - phase: :not_found → 404 风格 "Agent doesn't exist"
  """
  ...
end
```

router 新增（跟现有 `/identities/agents/:uri/caps` 和 `/:uri/api-keys`
兄弟）:
```elixir
live "/identities/agents/:uri/terminal", TerminalLive
```

### 3.4 cc plugin 收缩

迁移后 `apps/ezagent_plugin_cc/` 保留:
- `lib/ezagent_plugin_cc/application.ex` — 只 boot Channel + Bridge + TokenStore + Socket
- `lib/ezagent_plugin_cc/channel.ex` — Phoenix Channel for claude TUI WS
- `lib/ezagent_plugin_cc/bridge_registry.ex` — agent_uri → channel pid 绑定（CC 专属）
- `lib/ezagent_plugin_cc/mcp_config_writer.ex` — 给 spawn 的 claude 生成 `.mcp.json`
- `lib/ezagent_plugin_cc/token_store.ex` — CC bridge auth tokens
- `lib/ezagent_plugin_cc/socket.ex` — WS endpoint
- `lib/ezagent/template/cc_agent.ex` — template class；`spawns_with: [Ezagent.Domain.Pty.Server]`
  + cc 专属 env (CLAUDE_HOME, MCP config path 等)

删除: `lib/ezagent/plugin_cc/pty_server.ex`、
`lib/ezagent/plugin_cc/views/pty_view.ex`、
`lib/ezagent/behavior/pty.ex`（全部搬走）。

## 4. 跨 flavor 加入模式

任何想给自己的 agent 配本地 PTY 的 template 在 `spawns_with` 声明:

```elixir
defmodule EzagentPluginEcho.Template.EchoAgent do
  @moduledoc """
  Echo agent template — 可选配本地 PTY 做 shell-like echo 测试。
  当 `with_pty: true` 时，agent template instantiate 启一个
  跑 `/bin/echo` 或 `/bin/bash` 的 PtyServer。
  """
  @behaviour Ezagent.Kind.Template

  def template_name, do: "echo.agent"

  def instantiate(_name, %{"agent_uri" => uri_str, "with_pty" => true} = tmpl, ws_uri) do
    agent_uri = URI.parse(uri_str)
    # 1. spawn Agent Kind（别处已做）
    {:ok, _} = Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{uri: agent_uri, ...})
    # 2. spawn PtyServer sidecar
    {:ok, _} = Ezagent.Domain.Pty.start(agent_uri, %{
      cmd: Map.get(tmpl, "cmd", "/bin/bash -i"),
      cwd: Map.fetch!(tmpl, "cwd"),
      env: Map.get(tmpl, "env", %{})
    })
    {:ok, [agent_uri]}
  end

  def instantiate(_name, %{"agent_uri" => uri_str} = _tmpl, _ws_uri) do
    # 无 PTY — 只 Agent Kind。Terminal-view 不适用。
    agent_uri = URI.parse(uri_str)
    {:ok, _} = Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{uri: agent_uri, ...})
    {:ok, [agent_uri]}
  end
end
```

`with_pty: true` template 选项是通用的 —— 任何 plugin 设这个就免费
拿到 PTY。

`Ezagent.Domain.Agent.lifecycle_status/1`（Phase 9 V1）已经按 flavor
分派；扩展为当 template 有 `spawns_with: [...Pty.Server]` 时查
`Ezagent.Domain.Pty.alive?/1`。

## 5. UI 表面

### 5.1 Terminal 作为 Session view（现有，搬移）

`/sessions` 上的 view-switcher 当 session 任一 member 是 PTY-backed
Agent 时显示 "Terminal" tab。迁移后:

- `EzagentDomainUi.Pty.TerminalView` 是 SessionView 实现
- 检测: 查 Session members，每个 Agent URI 调
  `Ezagent.Domain.Pty.alive?/1`；任一 true 则 offer Terminal view
- 渲染: 默认选第一个 PTY-backed agent；用户可通过 terminal 上方的
  小下拉切换 PTY-backed agents

### 5.2 独立 Terminal 页（新增）

URL: `/identities/agents/:uri/terminal`（URL-encoded entity URI 作
`:uri` path segment —— 跟兄弟 `/identities/agents/:uri/caps` 和
`/:uri/api-keys` 一致约定）。

Use case（Allen #3 — agent detail 页）:
- 当前 `/identities/agents/:uri` "Open terminal" 按钮跳到 /sessions
  + 切到 PTY view —— 笨拙
- 本 SPEC 之后: 按钮 → `/identities/agents/:uri/terminal`
- 独立页 = 全屏聚焦 terminal，无 chat 干扰

渲染在 `IdeShell`（workspace 表面），所以导航 + 侧栏仍工作；主窗口 = terminal。

### 5.3 agent detail 内嵌 terminal（Allen #3）

`/identities/agents/:uri` 页当前有 "Open terminal (in Sessions)"
按钮。本 SPEC 之后:

- agent **有** PTY 时: detail 页**内嵌** terminal（默认折叠；
  "Open terminal" 按钮展开）。**不跳转**。
- agent **无** PTY 时（echo 没开 with_pty，curl 等）: 按钮不出现。

复用组件 `EzagentDomainUi.Pty.Terminal` —— 同样的 xterm.js hook，
只是放在不同 shell 里。

## 6. 生命周期集成

`Ezagent.Domain.Agent.lifecycle_status/1`（PR #175 V1 fix）返回
`%{phase, flavor, detail}`。本 SPEC 之后:

```elixir
def lifecycle_status(%URI{} = agent_uri) do
  kind_alive? = case Ezagent.KindRegistry.lookup(agent_uri) do
    {:ok, _pid} -> true
    :error -> false
  end

  pty_alive? = Ezagent.Domain.Pty.alive?(agent_uri)

  phase = cond do
    not kind_alive? -> :not_found
    pty_alive? -> :alive
    template_declares_pty?(agent_uri) -> :registered   # Kind alive 但 PtyServer 没起
    true -> :alive                                      # 不需要 PTY，Kind alive 就够
  end

  %{
    phase: phase,
    flavor: flavor_of(agent_uri),
    detail: pty_alive? && Ezagent.Domain.Pty.status(agent_uri) || %{}
  }
end
```

Q3 "统一生命周期 UI" 现在**完整**了 —— 同样的 status 格式给
cc / echo-with-pty / curl-without-pty / 未来 flavor。AgentDetailLive
已经用这个 facade（V1 fix #175）。

## 7. Capability 形态

`Ezagent.Behavior.Pty` cap 跟当前一致:
- `kind: :agent`
- `behavior: Ezagent.Behavior.Pty`
- `instance: entity://agent/<flavor>/<workspace>/<name>` 或 `:any`

Phase 9 PR-3 加的 `workspace_uri` 维度也适用。Admin 的全 `:any` cap
通过。

Behavior 模块换 app 但 cap shape 保留 —— DB 里现有 grant 仍然工作
（modules 在 `caps_json` 是字符串引用 → `Elixir.Ezagent.Behavior.Pty`
—— 搬完同名）。

## 8. 迁移计划

按 `feedback_let_it_crash_no_workarounds`: 不要 shim。

### 8.1 PR 序列（4 PRs）

| # | 标题 | 文件 | LOC 估 |
|---|------|------|--------|
| A | `ezagent_domain_pty` app 创建 + Server/Supervisor/Registry 搬 | 8（mix.exs + 新 app 结构）| 600 |
| B | `Ezagent.Behavior.Pty` 搬 + caller 更新 + grep `EzagentPluginCc.PtyServer` 引用 | 12 | 400 |
| C | `EzagentDomainUi.Pty.TerminalView` 搬 + xterm.js hook 移位 | 6 | 300 |
| D | `TerminalLive` 独立页 + AgentDetailLive 内嵌 terminal + /terminal/:agent_uri 路由 + cc plugin 收缩 | 10 | 500 |

D 后: cc plugin 小 ~40%（PtyServer + supervisor + registry + view + behavior 都没了）。`ezagent_domain_pty` 成 canonical 归宿。

### 8.2 每 PR 检查

- **编译 gate**: 每 PR 必须干净编译 + 测试通过
- **不留 backward-compat alias**（`alias Ezagent.PluginCc.PtyServer, as: ...`）— 修 caller
- **Invariant test**: `apps/ezagent_core/test/invariants/no_pty_in_plugin_cc_test.exs` — PR-D 后 grep gate 断言 lib 代码再无 `Ezagent.PluginCc.PtyServer` 引用

### 8.3 DB / 运行时 compat

- 现有 `kind_snapshots` 行 `kind_type: "agent"` 不变
- `cc.agent` template 存储的 `session_templates` JSON 不变
  （仍有 `agent_uri` + `cwd`）；cc.agent template 的 instantiate
  现在调 `Ezagent.Domain.Pty.start/2` 替代 inline
- 无 DB migration
- 无 restart-data-loss

## 9. Audit — 当前 PTY/erlexec 使用者

按 Allen audit 要求:

| 模块 | 用 PTY? | 状态 | SPEC 之后 |
|---|---|---|---|
| `Ezagent.PluginCc.PtyServer` | 是（canonical impl）| 搬到 `Ezagent.Domain.Pty.Server` | 从 plugin_cc 消失 |
| `EzagentPluginCc.Channel` | 否（只处理 WS）| 保留 | 不变 |
| `EzagentPluginEcho` | 今天否 | 可在 echo.agent template 通过 `with_pty: true` 加入 | 选项存在；默认不启用 |
| `EzagentPluginCurlAgent` | 今天否 | 可加入用于测试脚本 | 选项存在 |
| 未来 plugin | — | 用 `spawns_with: [Ezagent.Domain.Pty.Server]` | 统一模式 |

erlexec 是 scope 内**唯一** PTY backend（不做 native `Port.open(:spawn)`
因为 claude TUI 明确需要真 PTY）。

## 10. 决策（Allen 2026-05-21 review）

| # | 问题 | 决策 | 理由 |
|---|------|------|------|
| 1 | App 名 | **`ezagent_domain_pty`** | 匹配 `Ezagent.Domain.Pty` namespace；"terminal" 是 UI，PTY 是 runtime |
| 2 | TerminalLive 路由 | **`/identities/agents/:uri/terminal`** | 原 draft `/terminal/:agent_uri` 动词在前 —— 违反代码库 resource-first URL 约定。选择路径是 Phase 8b 废弃前的形态，跟兄弟 `/identities/agents/:uri/caps` + `/:uri/api-keys` 一致。LV-URL ↔ URI 映射约定见 §13 |
| 3 | Echo PTY 启用 | **AgentNewLive "with PTY" checkbox** for echo flavor（跟 cc 需要 cwd 一致）—— operator 自助，不是 admin-only template config |
| 4 | 进 Activity Bar | **不** —— terminal 是 agent 的 sub-view，不是 top-level activity。通过 `/identities/agents/:uri/terminal`（或 agent detail 页内嵌展开）到达更结构正确；Activity Bar 维持 4 项（Sessions / Identities / Routing / Plugins）|

## 11. 验证清单

4 个 PR 全部落地后:
1. ✅ `grep -r "EzagentPluginCc.PtyServer" apps/` 返回空
   （模块搬走，没留 alias）
2. ✅ `Ezagent.Domain.Pty.start(agent_uri, params)` 启 PtyServer；
   `Ezagent.Domain.Pty.alive?(agent_uri)` 返 true
3. ✅ cc.agent template 的 `instantiate/3` 调
   `Ezagent.Domain.Pty.start/2`
4. ✅ `/terminal/<encoded-cc-agent-uri>` 渲染 xterm.js terminal
5. ✅ `/identities/agents/<cc-agent-uri>` 显示内嵌 terminal 按钮（可展开）
6. ✅ AgentNewLive echo flavor 提供 "with PTY" checkbox；勾选后
   echo agent 拿到 `/bin/bash` PtyServer
7. ✅ `Ezagent.Domain.Agent.lifecycle_status/1` 对 cc + echo-with-pty
   agent 都报 `phase: :alive`，格式一致
8. ✅ Invariant test `no_pty_in_plugin_cc_test.exs` 通过

## 13. LV URL ↔ URI 系统映射约定

Allen Feishu 2026-05-21 15:17: "`/identities/agents/:uri/terminal`
这里是 LiveView 的 URL，还是我们的 URI 系统？现在 LiveView URL 和
URI 的关系是什么？"

**三层**对应清晰:

| 层 | 例 | 用途 |
|---|---|---|
| 浏览器 URL | `/identities/agents/entity%3A%2F%2Fagent%2Fdefault%2Fcc_demo/terminal` | bookmark / nav / 分享 |
| LV `:uri` 参数 | `entity://agent/default/cc_demo` | 桥接（Phoenix Router 自动 URL-decode）|
| 内部 URI 系统 | `%URI{scheme: "entity", host: "agent", path: "/default/cc_demo"}` | dispatch / cap matching / KindRegistry lookup |

**Mount-time 桥接**（`AgentDetailLive`、`EntityCapsLive`、未来
`TerminalLive` 用的模式）:

```elixir
def mount(%{"uri" => encoded_uri}, _session, socket) do
  decoded = URI.decode_www_form(encoded_uri)

  case URI.new(decoded) do
    {:ok, %URI{scheme: "entity", host: "agent", path: "/" <> _name} = agent_uri} ->
      {:ok, assign(socket, :agent_uri, agent_uri)}

    _ ->
      {:ok, socket |> put_flash(:error, "Invalid agent URI") |> push_navigate(to: ~p"/identities")}
  end
end
```

**这个桥接就是架构 seam**。seam 上方（浏览器/URL）一切都是 HTTP 层
addressing —— 字符串、URL-encoding、可 bookmark 路径。seam 下方
（LV/dispatch）一切都是 `%URI{}` struct 流过 Ezagent 内部 addressing
contract（cap、KindRegistry、Behavior dispatch、persistence）。

**ezagent 强制的约定**:

1. **LV 路由总是用 `:uri` 作 path 段名** for entity URI（跨所有
   `/identities/agents/:uri/*` 和 `/identities/users/:uri/*` 路由
   一致）
2. **`:uri` 值是 URL-encoded 的 canonical entity URI 字符串** —
   不是 DB ID，不是 slug，不是 short identifier
3. **LV mount/3 总是 URL-decode + URI.new() + pattern-match**
   on 预期 scheme/host 形态；无效 → flash + redirect
4. **进入 LV 后，只用 `%URI{}` struct** —— encoded 字符串不泄露
   到 mount 之外
5. **超链接通过 URI.encode_www_form(URI.to_string(uri)) 构造**
   URL —— 永不手写 path 字符串

**Trade-off（V1 不修）**:
- 浏览器 URL 难看 (`entity%3A%2F%2Fagent...`) 因为 URL-encoding
- 任何 URI scheme 改动（如 Phase 9 的 2→3 segment 迁移）会破坏 bookmark
- 备选 "flat path" 映射 (`/identities/agents/default/cc_demo` →
  重构 `entity://agent/default/cc_demo`) 会更干净但需要改所有
  link-builder。留 V2 考虑。

**为什么现在写这节**: V1 Domain.Pty 加了第三个 `/identities/agents/:uri/*`
sub-view 路由。不写这节，未来 contributor 可能不一致地重新发明桥接
（用不同 param 名、在 helper 里 decode、手写 path）。把 seam 写
文档化让模式可复制。

**main 上的参考实现**:
- `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/agent_detail_live.ex` — `parse_agent_uri/1` 模式
- `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/entity_caps_live.ex` — `/identities/agents/:uri/caps` 同样模式
- `apps/ezagent_plugin_liveview/lib/ezagent_plugin_liveview/user_api_keys_live.ex` — user 同样模式

## 12. 超出范围（V2+）

- Native `Port.open(:spawn)` backend（erlexec 之外的备选）
- Remote PTY proxy（PTY 跑在另一台机器；xterm.js 通过 tunnel 连接）
- PTY 录制 / 回放（asciinema 风格 replay）
- per-PTY 资源限制（CPU / mem quota）
- PTY transcript 持久化（今天全在内存；PtyServer 挂了 transcript 丢）
- V2 macro `spawn_pipeline` 集成 —— 本 SPEC 发原语；macro 工作是 V2 独立

---

## 实施指引

本 SPEC 批准后，通过 `superpowers:subagent-driven-development` 派 4 PR。
每个 subagent load `Skill: ezagent-developer`（特别是 Tier-2 规则 +
UI Contract）+ `Skill: elixir-phoenix-helper`。

Branch 模式: `feat/domain-pty-pr-<N>-<topic>`。Admin-merge 按
ezagent42/esr 标准模式。

英文版 `.md` 已写完；保持同步（按 `feedback_bilingual_docs_convention`）。
