# agent 的配置：#992 config 统一后，怎么建一个 agent、怎么挂真 brain

> 基线：`feat/kanban-agent-e2e`（2026-06-26，已合 #992 config 统一 + #1004/#1007 kanban-as-role + cc-headless 真 claude brain）。
> 本文每个论断都带 `file:line` 实证，全部用 skill-1（project-discussion-esr-ng）+ 真实读码核实过，没有臆测。
> 读者：第一次接触 ezagent 的人，看完应该能自己照着建一个 agent。

---

## 0. 先搞清楚四个词，不然全文看不懂

ezagent 里"建一个 agent"涉及四个互相正交的概念，先一句话讲明白，后面才不会绕：

| 词 | 大白话 | 它决定什么 | 真实代码锚点 |
|---|---|---|---|
| **flavor（口味/引擎）** | 这个 agent 用哪种引擎当大脑 | `cc` / `cc-headless` / `codex` / `curl` / `py` / `native` | `agent_flavors/0` 注册，见 `apps/ezagent_plugin_cc/lib/ezagent/plugin_cc/application.ex:100` |
| **role（角色/配方）** | 跟引擎无关的"内容配方"，给 agent 装一套行为 | 例：`kanban-manager` = 24 个看板动作 | `roles/0` 注册，见 `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/application.ex:64` |
| **config（配置）** | 这个 agent 自己的参数（模型、推理强度、权限模式…） | 由 flavor 的 `config_schema/0` 定字段 | `apps/ezagent_plugin_cc/lib/ezagent/template/cc_agent/config_schema.ex:5` |
| **caps（能力/授权）** | 谁能对这个 agent 做什么 | 建 agent 时自动 mint，读写 config 用 manage-cap 守 | `apps/ezagent_domain_agent/lib/ezagent/agent/config.ex:21` |

关键心智模型：**一个 agent = flavor（宿主引擎）× role（内容配方，可选）+ config（这台 agent 自己的参数）**。
- `cc` flavor 的 agent，大脑是 Claude Code，不一定挂 role；
- kanban 看板那种 agent，flavor 是通用宿主 `native`（自己没大脑），role 是 `kanban-manager`（内容全靠 role 配方）。

---

## 1. #992 之前 vs 之后：配置到底"统一"了什么

**统一的核心：每个 flavor 只写一份字段定义 `config_schema/0`，建表单、建时校验、详情展示三处自动一致，不再各写一份。**

### 1.1 字段定义的唯一真源 = flavor 的 `config_schema/0`

每个 flavor 背后有一个 Template Class（模块级"配方类"），它导出 `config_schema/0` 列出这个引擎能配哪些字段。

- **cc（Claude Code）**：`cc_agent.ex:275` 一行 `defdelegate config_schema, to: ...ConfigSchema, as: :fields`，真正的字段在 `apps/ezagent_plugin_cc/lib/ezagent/template/cc_agent/config_schema.ex:5`，四个字段：
  - `model`（字符串）
  - `effort`（枚举：default/low/medium/high）
  - `permission_mode`（枚举：default/acceptEdits/bypassPermissions/plan，默认 default）
  - `tools`（列表）
- **native（通用宿主）**：`apps/ezagent_plugin_native/lib/ezagent/template/native_agent.ex:28` 是 `def config_schema, do: []` —— **空的**。因为 native 本身没大脑、没参数，配置全由它挂的 role 提供（`native_agent.ex:13` 注释明说 "the role supplies everything"）。

每个字段是一个 map：`%{key, type, label, options, default}`。这套 schema 同时被三个地方读。

### 1.2 三个消费点（建表单 / 建时校验 / 详情展示）

1. **建 agent 的动态表单**（UI 侧读 schema 渲染字段）
   `apps/ezagent_plugin_world/lib/ezagent/world/identity_data.ex:580` —— `AgentFlavorRegistry.lookup(flavor)` → `tc.config_schema()` → 转成前端能用的 JSON（`schema_field_to_map/1`，`identity_data.ex:595`）。前端按你选的 flavor 渲染对应字段。

2. **建 agent 时按 schema 收口校验（ingest）** —— 这是 #992 最硬的一环
   提交的 flavor 配置走 `apps/ezagent_domain_workspace/lib/ezagent/behavior/workspace/agent_create/flavor_config.ex:9` 的 `coerce/2`：
   - 从 `AgentFlavorRegistry` 拿该 flavor 的 `config_schema`（`flavor_config.ex:35` 的 `fields/1`）得到允许的 key 集合；
   - 把提交的字段（顶层散的 + 嵌套在 `flavor_config` 里的）合并；
   - **任何不在 schema 里的 key 直接报错** `{:error, {:unknown_flavor_config_keys, flavor, unknown}}`（`flavor_config.ex:29`）。
   一句话：建 agent 时，你填的引擎参数会被这台 flavor 的 schema 白名单卡一遍，填错字段名直接拒。

3. **建好之后改配置（config 页）**：见下面第 3 节。

### 1.3 还没 100% 收敛的过渡残留（诚实标注，别误判）

- `identity_data.ex:621` 起有一张硬编码的 `template_field_keys_for/1`（cc/cc-headless/codex/curl 各列一串 key），是 M1 时代的残留，注释说 M2+ 由 `config_schema/0` 取代。
- `identity_data.ex:118` 的注释 `M2-mock: config schema (A4 落地后改为 tc.config_schema())` 也是同类过渡痕迹。
- 结论：**建时 ingest 校验（第 2 点）已经走真 schema 了，但详情页/部分 UI 仍有旧硬编码表没拆干净**。看到字段对不上别急着报 bug，先看是不是踩到这两处过渡残留。

---

## 2. 怎么从零建一个 agent（可执行步骤）

### 2.1 唯一入口：`Workspace.create_agent`，CLI 和 UI 共用一条码路

不管你从命令行还是从 world 界面建 agent，最终都打到同一个 Behavior：
`apps/ezagent_domain_workspace/lib/ezagent/behavior/workspace/agent_create.ex:25` 的 `handle_create_agent/2`。

它收的参数（`coerce_create_args/1`，`agent_create.ex:78`）：

| 参数 | 含义 | 必填 |
|---|---|---|
| `flavor` | 引擎类型，如 `"cc"` / `"native"` | 是 |
| `name` | agent 名字（URI-path-safe：字母开头 + 字母数字下划线连字符，`agent_create.ex:158`） | 是 |
| `cwd` | 工作目录 | 否（默认空） |
| `with_pty` | 是否带终端 | 否（默认 false） |
| `from` | 从某个已有 agent 克隆（`entity://.../agent/...`） | 否 |
| `role` | 角色配方名，如 `"kanban-manager"`（RF-5a role-create 路径） | 否 |
| 其余字段 | flavor 私有配置，进 `flavor_config` | 否 |

合法 flavor 由 `AgentFlavorRegistry` 决定；注册表为空时（裸单测）回退到白名单 `~w(cc curl np codex py)`（`agent_create.ex:140`）。

整个建 agent 的校验链（`agent_create.ex:29-41`）按顺序是：coerce 参数 → 校验 flavor 合法 → **FlavorConfig.coerce 按 schema 收口配置** → 校验 name → 校验 cwd → 校验 role 跟 flavor 匹配 → 拼 agent URI → 查重 → 解析克隆源 → `do_create_agent`。

### 2.2 UI 路径怎么把表单字段塞进去

world 前端建 agent 的回调走 `apps/ezagent_plugin_world/lib/ezagent/world/agent_actions.ex:27` 的 `handle_dispatch(socket, "agents.create", ...)`；它把表单里 flavor 专属字段收进 `config_fields`（`agent_actions.ex:64`），merge 进 `create_agent` 的 args（`agent_actions.ex:75`）。成功跳详情页，失败不静默——重推带 `create_error` 的状态。

### 2.3 一个普通 cc agent 的最小建法（概念示例）

```elixir
Ezagent.Workspace.create_agent(
  workspace_uri,
  %{
    flavor: "cc",
    name: "my_assistant",
    # 下面三个是 cc 的 config_schema 字段，会被 ingest 白名单放行
    model: "claude-...",
    effort: "high",
    permission_mode: "default"
  },
  caller_ctx  # %{caller: 人类用户URI, caps: 该用户的caps}
)
```

填了 schema 之外的 key（比如 `foo: 1`），`flavor_config.ex:29` 直接拒。

---

## 3. 建好之后怎么改配置：`Ezagent.Agent.Config` 门面

改配置不是直接写库，而是经 domain 层唯一稳定门面
`apps/ezagent_domain_agent/lib/ezagent/agent/config.ex`，五个函数：

| 函数 | 作用 | 行 |
|---|---|---|
| `read_cascade/4` | 读分层级联配置（workspace/user/session 三层叠加） | `config.ex:38` |
| `read_key/5` | 读某个 key | `config.ex:71` |
| `apply_delta/4` | 改配置（打补丁） | `config.ex:87` |
| `delete_path/4` | 删某个路径 | `config.ex:104` |
| `repoint/4` | 重指某层引用的配置对象 | `config.ex:129` |

**两个关键设计**：
1. 所有读写都 `Invocation.dispatch` 到目标 agent 自己的 `Behavior.ConfigEvolve`（`config.ex:222` 的 `dispatch/5`），不绕过 agent 进程直接碰存储。这是 P14（跨 Kind 只能走 dispatch）。
2. **读和写用同一把 manage-cap 守**（`config.ex:21` 注释）：没有这台 agent 的 manage-cap，读也会被拒返回 `{:error, :unauthorized}`。故意这么设计，避免"存在性 oracle"信息泄露（不让无权的人通过"读得到/读不到"探测 agent 存不存在）。

UI 侧改配置经 `agent_actions.ex` 的 `agents.config.update` / `delete_path` / `repoint`（`agent_actions.ex:35/39/43`），路由到 config 页 `/identities/agents/<uri>/config`。

### 3.1 api_keys 和 extensions（两个独立子面）

- **api_keys**：列在 `/identities/agents/<uri>/api-keys`，读经 dispatch `identity.list_api_keys`；能不能编辑由真实授权模型派生（admin 或 creator），不手搓判断以免和 dispatch 守卫漂移。注意写入路径不在 `AgentActions` 而在 `WorldLive` 本体（排查时容易找不到）。flavor 没实现 ApiKeys behavior 的（如 np）会优雅显示 `unsupported`。
- **extensions**：列在 `/identities/agents/<uri>/extensions`，读该 agent 的 config_dir，经它的 Template Class 的 `list_extensions/1` 列出 MCP/插件类扩展。

---

## 4. kanban-manager agent 怎么建（role × native 实例）

这是"建 agent"的一个特例，也是 #1007 kanban-as-role 的落地：**一张看板就是一个 agent**，不是独立的 `resource://kanban` Kind（旧 Plan-B 已删、被架构 gate 锁死）。

### 4.1 role 配方在哪注册

kanban 插件用 `roles/0` 在 boot 时注册 `kanban-manager` 配方
`apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/application.ex:64`，配方本体在同文件的 `kanban_manager_recipe/0`：
- `behaviors: [Ezagent.Behavior.Kanban]` —— 24 个看板动作全在这一个 Behavior 里；
- `passive: true` —— 看板是"被动数据 actor"：不可被 @、不收 chat，只在直接 `kanban.<action>` dispatch 上动作；
- `requested_caps` —— 每个动作一个 cap 模板，flavor 物化时由 `Role.CapMint` 注入 `:agent` 这个 kind 轴。

### 4.2 建一张看板 = 建一个 native flavor 的 agent

world 里建看板的代码 `apps/ezagent_plugin_world/lib/ezagent/world/kanban_actions.ex:296` 的 `create_kanban/2`，直接调：

```elixir
Ezagent.Workspace.create_agent(
  workspace_uri,
  %{
    flavor: "native",        # 通用宿主，自己没大脑
    name: clean,
    role: "kanban-manager",  # 内容配方
    cwd: "",
    with_pty: false
  },
  caller_ctx
)
```

成功后 `entity://<workspace>/agent/<name>` 既是这张看板的地址，也是后续所有节点操作的 dispatch 目标。所有节点操作经
`Ezagent.URI.with_action(uri, :kanban, action)` 打到 `Behavior.Kanban`（即 `entity://...?action=kanban.<action>`）。

> 一句话区分：cc agent 是"有大脑、可能没 role"；kanban agent 是"没大脑（native）、全靠 role 撑内容"。两者走的是同一条 `create_agent` 码路，只是 flavor/role 参数不同。

---

## 5. cc-headless 真 claude brain 怎么挂

cc-headless 是把"真正的 Claude Code 大脑"挂上去的 flavor，和普通 `cc` 的区别是：**无 PTY/TUI、跑一个 Python 的 Claude Code SDK sidecar 当大脑**。

### 5.1 flavor 注册：多了三样东西

`apps/ezagent_plugin_cc/lib/ezagent/plugin_cc/application.ex:111` 注册 `cc-headless` flavor：

```elixir
%{
  flavor: "cc-headless",
  kind: Ezagent.Entity.Agent,                                  # 还是共享的 agent Kind
  template_class: Ezagent.PluginCc.Template.CcHeadlessAgent,   # 它的配方类
  bridge_adapter: EzagentPluginCc.CcHeadlessBridgeAdapter,     # 桥接内核的 adapter
  instance_behaviors: &Ezagent.Entity.Agent.cc_headless_behaviors/0  # 多挂一个 behavior
}
```

对比上面 `cc`（`application.ex:103`）：cc-headless 多了 `instance_behaviors`，挂的是
`apps/ezagent_domain_agent/lib/ezagent/entity/agent.ex:139`：
```elixir
def cc_headless_behaviors, do: base_behaviors() ++ [Ezagent.Behavior.CcHeadlessAgent]
```
即在通用 agent 行为基础上，额外挂一个 `Behavior.CcHeadlessAgent`，让这台 agent 能接收消息并转给真大脑。

### 5.2 真大脑本体 = Python SDK sidecar，每台 agent 一个

`apps/ezagent_plugin_cc/lib/ezagent/plugin_cc/sdk_sidecar.ex:1`（`EzagentPluginCc.SdkSidecar`）：
- 是一个被监督的 GenServer，**一台 cc-headless agent 一个**；
- 内部起一个 Python worker（`ClaudeSDKClient`），用 stdin/stdout JSON 行通信，worker 持有 SDK client，串行化 `query + receive_response`；
- worker 经 `Ezagent.Runtime.OsProcess`（erlexec `run_link` + 进程组 kill）启动，保证任何退出路径都能把 uv→python 整组回收（`sdk_sidecar.ex` moduledoc）。

### 5.3 凭证：复用 cc 那套

cc-headless 的 Template Class `apps/ezagent_plugin_cc/lib/ezagent/template/cc_headless_agent.ex:1` 明说"same CredentialAdapter as cc"，凭证相关回调全 `defdelegate` 给 `CcAgent`（同 `CLAUDE_CONFIG_DIR` + `.credentials.json`，见 `cc_headless_agent.ex:25-31`）。config_dir 命名空间是 `"cc-headless"`（`cc_headless_agent.ex:18`）。

### 5.4 怎么建一个 cc-headless agent

跟 2.3 一样走 `create_agent`，flavor 填 `"cc-headless"` 即可：

```elixir
Ezagent.Workspace.create_agent(
  workspace_uri,
  %{flavor: "cc-headless", name: "real_brain", model: "claude-...", effort: "high"},
  caller_ctx
)
```

config 字段沿用 cc 的 `config_schema`（`cc_agent/config_schema.ex:5` 的 model/effort/permission_mode/tools）。建好后，发给这台 agent 的消息经 `Behavior.CcHeadlessAgent` 转给它专属的 `SdkSidecar`，由真 Claude Code SDK 出结果。

> 运行依赖：cc-headless 需要 `uv` + Python（跑 SDK sidecar）和有效的 `claude` 凭证。环境缺这些大脑起不来。

---

## 6. 一页速查表

| 我想… | 怎么做 | 锚点 |
|---|---|---|
| 建普通 Claude agent | `create_agent(ws, %{flavor: "cc", name, model, effort, permission_mode}, ctx)` | `agent_create.ex:25` |
| 建真大脑 agent | 同上，`flavor: "cc-headless"` | `application.ex:111` |
| 建一张看板 | `create_agent(ws, %{flavor: "native", name, role: "kanban-manager"}, ctx)` | `kanban_actions.ex:296` |
| 知道某 flavor 能配哪些字段 | 读它的 `config_schema/0` | `cc_agent/config_schema.ex:5`、`native_agent.ex:28` |
| 改一个已建 agent 的配置 | `Ezagent.Agent.Config.apply_delta/4`（manage-cap 守） | `config.ex:87` |
| 看为什么填错字段被拒 | FlavorConfig 白名单 ingest | `flavor_config.ex:29` |

---

## 7. 三个容易踩的坑

1. **flavor 和 role 不是一回事**：flavor 决定引擎/大脑，role 决定内容配方。native 是"没大脑的壳"，专门给 role agent（如 kanban）当宿主用。
2. **config 读也要权限**：没 manage-cap 连读都被拒（`config.ex:21`），这是故意防信息泄露，不是 bug。
3. **#992 还没 100% 收敛**：建时校验已走真 `config_schema`，但 `identity_data.ex:621` 的 `template_field_keys_for/1` 和 `:118` 的 M2-mock 注释是旧硬编码残留，详情页部分字段还没切过去。看到 UI 字段对不上先排查这两处，别当回归。
