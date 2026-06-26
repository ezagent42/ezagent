# Phase 2 — 抽出 `ezagent_plugin_github` + 自动 CI 闭环

> 日期 2026-06-26 ｜ 基线 `feat/kanban-agent-e2e`（含 #1004/#1007 + RF-1..9 + #1012）。
> 上位设计（真相源）：`docs/discuss/2026-06-26-kanban-team-flow-spec.md` §6/§7（GH/CI 行）、
> `docs/discuss/2026-06-26-kanban-flow-redesign/flow-redesign.md` §6（github 边界）、
> `docs/discuss/2026-06-26-kanban-flow-redesign/missing-capabilities.md` §2（入站细节）。
> 写代码/review 前先 `load skill ezagent-developer`（P14 / lifecycle 契约 / 三层铁律）。

---

## Goal

把 kanban 插件里**全部 github 代码**（出站 HTTP 客户端 + 4 个连接器动作的 github 部分 +
B2 推 commit status + sync_prs 轮询）抽进一个**新独立 OTP plugin** `:ezagent_plugin_github`，
并补一条 **github→ezagent 入站路径**（轮询 `GET /repos/<repo>/pulls?state=open`，按分支名
`head_ref` 匹配看板节点 → 自动 `register_pr`；merged/closed → 自动 `set_status done`）。

抽完之后：

- **kanban 不含一行 github 代码**：只留 board 真相源 + CI 判据**计算**（`check_pr_gate` /
  `gate_state` / `requirement_digest` 全在 `EzagentPluginKanban.Ci`，纯函数读 board，不动）。
- **github token 归新 plugin**（`system://credentials/github.yaml` 的读写都搬到新 plugin）。
- **kanban ↔ github 全程 `Ezagent.Invocation.dispatch/1`（P14）**：
  - kanban 出站动作（`sync_github`/`push_pr`）→ dispatch 到 github gateway agent 做 HTTP；
  - github 入站轮询器 → dispatch 回 kanban（`register_pr`/`set_status`）。
- **人工断点拔掉**：PR 在 GitHub 出现 → 自动登记 → CI 硬门自动推 → merged 自动 done，全无人手填。

交付验收（SPEC §7 Phase 2）：github 独立成 plugin、kanban 不含 github 代码；真 test-ezagent
repo e2e（开 PR→自动 register→自动 status→merge→自动 done）+ **每步截图**。

---

## Architecture

### 抽出后的两半（互补，全程 dispatch）

```
                 ┌─────────────────────── ezagent_plugin_kanban ───────────────────────┐
                 │  Behavior.Kanban (board 真相源 :kanban slice)                          │
                 │   · sync_github  handler ── dispatch ──┐   · register_pr  (KEEP, 写 board)│
                 │   · push_pr      handler ── dispatch ──┤   · set_status   (KEEP, 写 board)│
                 │   · Ci.check_pr_gate/gate_state/digest  │   (CI 判据计算，纯函数，留 kanban) │
                 │   · BoardConfig.github_repo (一图一仓，留 kanban；token 不在这)            │
                 └────────────────────────────────────────┼───────────────────▲─────────┘
                                                           │ Invocation.dispatch │ Invocation.dispatch
                                                           ▼                     │ (register_pr / set_status)
                 ┌────────────────────────── ezagent_plugin_github ──────────────┴─────────┐
                 │  Behavior.Github  on  github-gateway agent (native flavor, 系统种子)        │
                 │   actions: create_issue / post_comment / get_pull /                       │
                 │            create_commit_status / bind_repo / save_creds / status          │
                 │   → EzagentPluginGithub.Client (:httpc + Jason, github.yaml token)         │
                 │                                                                            │
                 │  EzagentPluginGithub.Sync  (per-board 轮询 GenServer，仿 MiroSync)          │
                 │   每 tick: list_open_pulls → match head_ref→node(dispatch get_tree) →       │
                 │            dispatch register_pr;  merged/closed → dispatch set_status done   │
                 │   幂等: Idempotency.seen?({board, pr, head_sha})                            │
                 └────────────────────────────────────────────────────────────────────────┘
```

### github gateway 宿主 = role `github-gateway` × flavor `native`（系统种子）

无状态 HTTP 网关，无子进程 → 用 **native flavor**（`apps/ezagent_plugin_native/lib/ezagent_plugin_native/application.ex:87`
的 generic 无引擎宿主），不用 py 的 own-Kind+subprocess。boot 时种一个系统单例
`entity://system/agent/github_gateway`（仿 py `seed_default/0`，
`apps/ezagent_plugin_py/lib/ezagent_plugin_py/application.ex:217`，但走 `Workspace.create_agent`
flavor `native` × role `github-gateway`，对齐 kanban-as-role 的 create 路）。`Behavior.Github`
经 `roles/0` recipe 经 RF-1 per-instance 挂在 generic `Entity.Agent` 宿主上。

> **设计 checkpoint（task 3 开工前确认，非 core 改动）**：gateway 宿主选 role×native（domain
> 运行期依赖）vs own-Kind à la py（core-only 依赖）。本计划选 role×native（匹配 kanban-as-role、
> 无子进程更轻）。`Behavior.Github` + `Client` + `Sync` 三者**宿主无关**，若 Allen 偏好 own-Kind
> 仅换宿主声明，其余不动。两条都不碰 core，故不属"近 core 等 Allen"的 E 类。

### per-board 入站轮询（仿 MiroSync，plugin 自有进程，不复用 external_mirror 域）

`EzagentPluginGithub.Sync` 一字不差照 `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/miro_sync.ex`
的形态：`{Registry, keys: :unique}` + `{DynamicSupervisor, one_for_one}` 在 github plugin
`children/0`；按 board URI 唯一注册；`bind(board_uri, repo, opts)` 起轮询；`sync_now/1` 手动跑一轮；
dispatch 身份 = 系统 admin（`miro_sync.ex:183-184` 的 `sys_caller`/`sys_caps` 先例）。绑定由 kanban
`set_board_config` 写 github_repo 时 dispatch github gateway `bind_repo` 触发（kanban→github，P14）。

### 分支名 → 节点匹配约定（轮询命门，missing-capabilities §2.5）

dev-together per-task 分支命名里编码 board 节点 id。Phase 2 约定 **`head_ref` 含节点 id**
即匹配（节点 id 是 board tree 里短的唯一串，`shared.ex` 的 `seq` 递增）。`Sync.match_node/2`：
`Enum.find(nodes, fn {id, _n} -> String.contains?(head_ref, id) end)`。无匹配 → 跳过（不报错、
telemetry 出口，非静默丢）。约定写进 `Sync` moduledoc + Phase 3 dev-together 分支命名对齐。

---

## Global Constraints

1. **命名**：app atom `:ezagent_plugin_github`，模块前缀 **`EzagentPluginGithub`**。
   > ⚠️ 任务书写"EsrPluginGithub 前缀"，但**全部现有 plugin 用 `EzagentPlugin<Name>`**
   > （`EzagentPluginKanban` / `EzagentPluginEmail` / `EzagentPluginPy`）；CLAUDE.md 命名表的
   > `EsrPlugin<Name>` 是 stale。按 ezagent-developer skill「code wins」+ 兄弟一致性，**用
   > `EzagentPluginGithub`**。Behavior 命名 `Ezagent.Behavior.Github`（`Ezagent.Behavior.<Name>` 约定）。
2. **三层铁律**：连接器/Behavior/轮询器全在 plugin；UI 在 world；**core 不碰**。跨 Kind/跨 plugin
   走 `Ezagent.Invocation.dispatch/1`（P14）。plugin→plugin **不允许编译依赖**——kanban 永远不
   `alias`/`import` `EzagentPluginGithub.*`，反之亦然，全靠 dispatch URI。
3. **Behavior 只 `use Ezagent.Lifecycle`**（2026-05-29 契约，SOLE 开发者面）。`Behavior.Github`
   无持久状态（HTTP 网关）：`create/1` 返回空 `state`，handler 返回 `{:ok, result, []}`（无
   `{:set,...}`，不写快照）。禁 `use Ezagent.Behavior` / `invoke/4` / `init_slice`（lifecycle gate 硬拒）。
4. **可靠性原语**（P22）：入站轮询走 `Ezagent.Idempotency.seen?/1`+`record/1`
   （`apps/ezagent_core/lib/ezagent/idempotency.ex:26/41`）；dispatch 失败 telemetry 出口，不静默丢。
5. **sanctioned URI 构造**：dispatch target 一律 `Ezagent.URI.with_action(uri, :behavior, :action)`
   （`apps/ezagent_core/lib/ezagent/uri.ex:379`），**不拼裸 `?action=` 串**（过 `uri_query.scan` gate）。
6. **凭证写盘 idiom**：`FsResolver.path!` + `File.write` + `chmod 0o600`（github.ex:41-44 原样搬）。
7. **每个 task = TDD 五步**：写失败测试 → 跑红 → 实现 → 跑绿 → commit。每 task 收尾跑 gate：
   - `MIX_ENV=test mise exec -- mix ezagent.check_invariants.lifecycle`
   - `mise exec -- mix format --check-formatted`（只测改动文件）
   - `mise exec -- mix ezagent.arch.scan` + `mix ezagent.uri_query.scan`
   - 涉及该 app 的 `bash scripts/test-app.sh <app>`（umbrella 上下文，**绝不 `cd apps/X`**）。
8. **跑测试环境**：先 `docker compose -f docker-compose.pg.yml up -d` 起 PG@55432 +
   `MIX_ENV=test mise exec -- mix ecto.create && mix ecto.migrate`；全程 `mise exec`（OTP27/1.18）。
9. **截图**：每个有意义步骤截图（配置→chat→操作→结果），用 agent-browser headless Chrome，
   remote URL 用 `100.64.0.27`（Tailscale IP）。

---

## Task 1 — Scaffold `ezagent_plugin_github` 空 app（编译 + plugin 契约绿）

**Files**
- 新建 `apps/ezagent_plugin_github/mix.exs`
- 新建 `apps/ezagent_plugin_github/lib/ezagent_plugin_github/application.ex`
- 新建 `apps/ezagent_plugin_github/test/test_helper.exs`
- 新建 `apps/ezagent_plugin_github/test/application_test.exs`

**Interfaces**
- `EzagentPluginGithub.Application` `use Application` + `use Ezagent.Plugin`；`start/2 → Ezagent.Plugin.boot(__MODULE__)`；`plugin_info/0`。

**Steps**
1. 写 `mix.exs`，照 `apps/ezagent_plugin_kanban/mix.exs` 骨架（`build_path`/`config_path`/`deps_path`/`lockfile`
   全 `../../`，`compilers: Mix.compilers() ++ [:ezagent_plugin_check]`，`env: [ezagent_plugin: EzagentPluginGithub.Application]`）：
   ```elixir
   def application do
     [
       mod: {EzagentPluginGithub.Application, []},
       env: [ezagent_plugin: EzagentPluginGithub.Application],
       extra_applications: [:logger, :inets, :ssl, :crypto]  # :httpc github client
     ]
   end
   defp deps do
     [
       {:ezagent_core, in_umbrella: true},
       {:jason, "~> 1.2"},
       # boot 种 github-gateway（native×role）+ e2e：role-create 路在 workspace/agent/session 域。
       # plugin→domain 是允许的依赖箭头（对齐 kanban mix.exs 的 test-only domain 依赖）；
       # 因 after_boot 种子是运行期，这里是完整依赖（非 only: :test）。
       {:ezagent_plugin_native, in_umbrella: true},
       {:ezagent_domain_workspace, in_umbrella: true},
       {:ezagent_domain_agent, in_umbrella: true},
       {:ezagent_domain_session, in_umbrella: true}
     ]
   end
   ```
2. 写 `application.ex`（先**只**留 `plugin_info/0`，其余 callback 走默认 `[]`/`nil`）：
   ```elixir
   defmodule EzagentPluginGithub.Application do
     @moduledoc "GitHub plugin OTP app + Ezagent.Plugin 契约：出站 gateway + 入站轮询（Phase 2 抽自 kanban）。"
     use Application
     use Ezagent.Plugin
     @impl Application
     def start(_type, _args), do: Ezagent.Plugin.boot(__MODULE__)
     @impl Ezagent.Plugin
     def plugin_info,
       do: %{slug: "github", name: "GitHub", description: "GitHub 出站(issue/PR评论/status)+入站(PR轮询自动登记)。", version: "0.1.0"}
   end
   ```
3. `test_helper.exs`：`ExUnit.start()`。
4. `application_test.exs`（失败测试先行）：
   ```elixir
   test "plugin_info slug/name 就位" do
     info = EzagentPluginGithub.Application.plugin_info()
     assert info.slug == "github" and info.name == "GitHub"
   end
   ```

**Run**（期望）
```bash
docker compose -f docker-compose.pg.yml up -d
MIX_ENV=test mise exec -- mix deps.get
mise exec -- mix compile                          # 期望：github app 编译过，:ezagent_plugin_check 绿
bash scripts/test-app.sh ezagent_plugin_github    # 期望：1 test, 0 failures
```

---

## Task 2 — 搬出站 HTTP 客户端 → `EzagentPluginGithub.Client`（+ `list_open_pulls`）

**Files**
- 新建 `apps/ezagent_plugin_github/lib/ezagent_plugin_github/client.ex`
- 新建 `apps/ezagent_plugin_github/test/client_test.exs`
- （删除留 task 5）`apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/github.ex`

**Interfaces**（搬自 `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/github.ex`，逐函数对照）
- `read_creds/0`（github.ex:19）/ `write_creds/1`（github.ex:35）— **token 归本 plugin**，URI 仍
  `Ezagent.URI.system("credentials", "github.yaml")`。
- `create_issue/4`（github.ex:59）/ `post_comment/4`（github.ex:70）/ `get_pull/3`（github.ex:88）/
  `create_commit_status/5`（github.ex:117）— 逐字搬，body 不变。
- **新增** `list_open_pulls/2`（入站轮询用）：
  ```elixir
  @doc "列出 repo 的 open PR（入站轮询）。返回 [%{number, head_ref, head_sha, state, merged}]。"
  @spec list_open_pulls(String.t(), String.t()) :: {:ok, [map()]} | {:error, term()}
  def list_open_pulls(token, repo) do
    case get(token, "/repos/#{repo}/pulls?state=open&per_page=100") do
      {:ok, list} when is_list(list) ->
        {:ok,
         Enum.map(list, fn m ->
           %{
             number: Map.get(m, "number"),
             head_ref: get_in(m, ["head", "ref"]),
             head_sha: get_in(m, ["head", "sha"]),
             state: Map.get(m, "state"),
             merged: Map.get(m, "merged", false)
           }
         end)}
      {:ok, other} -> {:error, {:unexpected_response, other}}
      {:error, _} = err -> err
    end
  end
  ```
- private `post/3`/`get/2`/`headers/1`/`maybe_put/3`/`blank_to_nil/1`（github.ex:140-172）逐字搬；
  `headers/1` 的 `User-Agent` 从 `~c"ezagent-kanban"` 改 `~c"ezagent-github"`。

**Steps**
1. `client.ex`：`defmodule EzagentPluginGithub.Client do ... end`，把 github.ex **第 12-172 行的常量
   + 全部公私函数原样复制进来**（module rename `EzagentPluginKanban.Github → EzagentPluginGithub.Client`），
   追加上面 `list_open_pulls/2`。moduledoc 改成"出站 HTTP 客户端 + 入站 list PRs（github plugin 自有）"。
2. `client_test.exs`（失败先行，纯解析/helper 测，不打真网）：
   ```elixir
   test "blank_to_nil + read_creds token_missing 路径可达" do
     # write 一个只有 access_token、repo 空的 yaml → read 回 repo: nil
     assert :ok = EzagentPluginGithub.Client.write_creds(%{access_token: "ghp_x", repo: ""})
     assert {:ok, %{token: "ghp_x", repo: nil}} = EzagentPluginGithub.Client.read_creds()
   end
   ```
   （写盘走 FsResolver 测沙箱目录，对齐 github 现状测路径；若现有 kanban 无对应单测，照
   `apps/ezagent_plugin_kanban/test/` 邻近 FsResolver idiom 设置临时 system root。）

**Run**（期望）
```bash
bash scripts/test-app.sh ezagent_plugin_github    # 期望：client 测全绿
```

---

## Task 3 — `Ezagent.Behavior.Github` 出站 gateway + boot 种子（dispatch 面）

**Files**
- 新建 `apps/ezagent_plugin_github/lib/ezagent/behavior/github.ex`
- 改 `apps/ezagent_plugin_github/lib/ezagent_plugin_github/application.ex`（加 `roles/0` + `after_boot/0` + `children/0` 占位）
- 新建 `apps/ezagent_plugin_github/test/behavior/github_test.exs`
- 新建 `apps/ezagent_plugin_github/test/gateway_seed_test.exs`

**Interfaces** — `Ezagent.Behavior.Github`（`use Ezagent.Lifecycle`），actions（全 `modes: [:call]`，
cap 轴 `:any`，对齐 `kanban.ex:284` 的 `cap(:any, __MODULE__, action)`）：

| action | args | returns |
|---|---|---|
| `create_issue` | `%{repo, title, body}` | `%{number, url}` |
| `post_comment` | `%{repo, number, body}` | `%{url}` |
| `get_pull` | `%{repo, number}` | `%{state, merged, head_ref, head_sha}` |
| `create_commit_status` | `%{repo, sha, state, context, description}` | `%{url}` |
| `bind_repo` | `%{board_uri, repo}` | `%{bound: true}` |
| `save_creds` | `%{access_token, repo}` | `%{}` |
| `status` | `%{}` | `%{configured, repo}` |

**Steps**
1. Behavior 骨架（无持久状态、handler 内 `Client.read_creds` 取 token、纯出站、`{:ok, result, []}`）：
   ```elixir
   defmodule Ezagent.Behavior.Github do
     @moduledoc "GitHub 出站 gateway Behavior（dispatch 面）：kanban 经 Invocation.dispatch 调；token 归本 plugin。"
     use Ezagent.Lifecycle
     alias EzagentPluginGithub.Client

     action(:create_issue, args: %{repo: :string, title: :string, body: :string},
       returns: %{number: :integer, url: :string}, caps: [:create_issue], modes: [:call],
       description: "在 repo 建 issue")
     # ... 同构声明 post_comment / get_pull / create_commit_status / bind_repo / save_creds / status

     @impl Ezagent.Lifecycle
     def create(_args), do: {:ok, %{}}   # 无持久状态

     @impl Ezagent.Lifecycle
     def handle_create_issue(%{repo: repo, title: title, body: body}, _ctx) do
       with_token(fn token ->
         case Client.create_issue(token, repo, title, body) do
           {:ok, r} -> {:ok, r, []}
           {:error, reason} -> {:error, gh_reason(reason)}
         end
       end)
     end
     # handle_post_comment / handle_get_pull / handle_create_commit_status 同款薄包

     def handle_bind_repo(%{board_uri: b, repo: repo}, _ctx) do
       {:ok, _} = EzagentPluginGithub.Sync.bind(URI.parse(b), repo, [])   # task 4 提供
       {:ok, %{bound: true}, []}
     end

     def handle_save_creds(%{access_token: t} = a, ctx) when is_binary(t) do
       if admin?(ctx), do: (Client.write_creds(%{access_token: t, repo: Map.get(a, :repo, "")}); {:ok, %{}, []}),
         else: {:error, :unauthorized}
     end

     def handle_status(_a, _ctx) do
       case Client.read_creds() do
         {:ok, %{token: t, repo: r}} when is_binary(t) and t != "" -> {:ok, %{configured: true, repo: r}, []}
         _ -> {:ok, %{configured: false, repo: nil}, []}
       end
     end

     @doc false
     def required_caps,
       do: for(a <- actions(), into: %{}, do: {a, Ezagent.Capability.cap(:any, __MODULE__, a)})
     @doc false
     def data_owner(_), do: :no_owner
     # with_token / gh_reason / admin? 私有 helper（gh_reason 搬自 connectors.ex:370-375；
     # admin? 照 shared.ex:41 的 caps 判定 idiom）
   end
   ```
   > `bind_repo` handler 直接调同 plugin 的 `Sync.bind`（同 app 内允许直引，非跨 plugin）——对齐
   > kanban `Connectors.sync_miro` 在 handler 内直调 `MiroSync.sync_or_bind`（connectors.ex:225）。
2. `application.ex` 加：
   ```elixir
   @gateway_role "github-gateway"
   @impl Ezagent.Plugin
   def roles, do: [%{name: @gateway_role, behaviors: [Ezagent.Behavior.Github],
       requested_caps: for(a <- Ezagent.Behavior.Github.actions(), do: %{behavior: Ezagent.Behavior.Github, action: a})}]
   @impl Ezagent.Plugin
   def after_boot, do: seed_gateway()
   @doc "种系统单例 github-gateway（仿 py seed_default，native×role；boot-safe：失败 log + :ok）。"
   def seed_gateway do
     ws = Ezagent.URI.workspace(:system)
     ctx = %{caller: Ezagent.URI.user(:system, :admin), caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()]), reply: :sync}
     case Ezagent.Workspace.create_agent(ws, %{flavor: "native", role: @gateway_role, name: "github_gateway"}, ctx) do
       {:ok, _} -> :ok
       {:error, :already_exists} -> :ok   # 幂等（re-boot / 重复种）
       {:error, reason} -> require Logger; Logger.warning("github seed_gateway 失败: #{inspect(reason)}; 首次 dispatch 自愈"); :ok
     end
   end
   def gateway_uri, do: Ezagent.URI.new!("entity://system/agent/github_gateway")
   ```
   > `Workspace.create_agent/3` 签名见 `apps/ezagent_domain_workspace/lib/ezagent/workspace.ex:760`；
   > flavor `native` 见 `apps/ezagent_plugin_native/lib/ezagent_plugin_native/application.ex:87`。
   > **task 3 开工先确认** create_agent 的 args 键名（`flavor`/`role`/`name`）+ 返回值形态，按
   > `apps/ezagent_plugin_kanban/test/kanban_role_test.exs` 的 role-create e2e 用法核对再写。
3. 失败测试：
   - `github_test.exs`：注 `Client` 的 stub（Mox 或 `dispatch_fun` 风格注入），断 `handle_create_issue`
     把 `{repo,title,body}` 透传给 Client、`{:ok,%{number,url},[]}` 回传；`handle_status` 无凭证→`configured: false`。
   - `gateway_seed_test.exs`：`seed_gateway/0` 跑完 `RoleRegistry.lookup("github-gateway")` 命中
     `behaviors: [Ezagent.Behavior.Github]`（对齐 `kanban_role_test.exs:39` round-trip 断言）；幂等二次种 `:ok`。

**Run**（期望）
```bash
MIX_ENV=test mise exec -- mix ezagent.check_invariants.lifecycle   # 期望：github Behavior 无 use Ezagent.Behavior 违规
bash scripts/test-app.sh ezagent_plugin_github                     # 期望：behavior + seed 测全绿
```

---

## Task 4 — `EzagentPluginGithub.Sync` 入站轮询器（仿 MiroSync）+ children 接线

**Files**
- 新建 `apps/ezagent_plugin_github/lib/ezagent_plugin_github/sync.ex`
- 改 `apps/ezagent_plugin_github/lib/ezagent_plugin_github/application.ex`（`children/0` 加 Registry+DynamicSupervisor）
- 新建 `apps/ezagent_plugin_github/test/sync_test.exs`

**Interfaces**（逐函数照 `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/miro_sync.ex`）
- `start_link/1` / `bind/3`（miro_sync.ex:38）/ `unbind/1` / `sync_now/1`（miro_sync.ex:48）/ `via/1`（:83）。
- `@registry EzagentPluginGithub.SyncRegistry` / `@supervisor EzagentPluginGithub.SyncSupervisor`。
- dispatch 身份：`sys_caller/0`+`sys_caps/0`（miro_sync.ex:183-184 逐字搬）。
- `dispatch_fun`/`token` 经 app env seam（仿 email inbound.ex:272-279），测试可注入、不打真网。

**Steps**
1. `sync.ex`：`use GenServer`，state `%{board_uri, repo, interval}`（无映射，github 无回声基线）。
   `init/1` 同 miro_sync.ex:86（`interval>0` 才 `Process.send_after(:tick)`）。核心 `sync/1`：
   ```elixir
   defp sync(state) do
     with {:ok, token} <- token(),
          {:ok, prs} <- Client.list_open_pulls(token, state.repo),
          {:ok, tree} <- read_tree(state.board_uri) do
       Enum.each(prs, fn pr -> maybe_register(state, tree, pr) end)
       advance_merged(state, tree, token)     # merged/closed → set_status done
       {:ok, %{open: length(prs)}}
     else
       {:error, _} = err -> err
     end
   end

   # 入站：新 open PR 按 head_ref 匹配节点 → 幂等 → dispatch register_pr。
   defp maybe_register(state, tree, %{number: num, head_ref: ref, head_sha: sha}) when is_integer(num) do
     key = {:gh_pr, URI.to_string(state.board_uri), num, sha}
     case match_node(tree, ref) do
       {id, _node} ->
         unless Ezagent.Idempotency.seen?(key) do
           dispatch_kanban(state.board_uri, "register_pr", %{id: id, pr: "##{num}"})
           Ezagent.Idempotency.record(key)
         end
       nil -> :ok   # 无匹配节点：telemetry 出口，跳过（非静默丢）
     end
   end
   defp maybe_register(_, _, _), do: :ok

   # head_ref 含节点 id 即匹配（Phase 2 约定，见 moduledoc / Architecture）。
   defp match_node(%{nodes: nodes}, head_ref) when is_binary(head_ref),
     do: Enum.find(nodes, fn {id, _n} -> String.contains?(head_ref, id) end)
   defp match_node(_, _), do: nil
   ```
   `advance_merged/3` 把 kanban `Connectors.advance_merged_prs`（connectors.ex:341-356）的语义搬来：
   遍历挂了 pr artifact 的节点 → `Client.get_pull` → merged/closed → `dispatch_kanban set_status %{id, status: "done"}`。
   `read_tree`/`dispatch_kanban`/`do_dispatch` 照 miro_sync.ex:161-181（`with_action(uri, :kanban, action)` +
   系统身份 + `mode: :call`）。
2. `application.ex` `children/0`：
   ```elixir
   @impl Ezagent.Plugin
   def children do
     base = [
       {Registry, keys: :unique, name: EzagentPluginGithub.SyncRegistry},
       {DynamicSupervisor, name: EzagentPluginGithub.SyncSupervisor, strategy: :one_for_one}
     ]
     # 测试 boot 不起任何 live 轮询（Registry/Sup 仍起，供 sync_now 单测手动 bind）。
     base
   end
   ```
3. 失败测试 `sync_test.exs`（注入 `dispatch_fun` + stub `list_open_pulls`，断行为，不打真网）：
   - open PR 分支名含节点 id → 调一次 `register_pr`（args `%{id, pr: "#N"}`）；
   - 同 PR + 同 sha 第二 tick → **不重复**（Idempotency）；
   - 分支名不含任何节点 id → 不 dispatch（跳过）；
   - 挂 pr 的节点 `get_pull → merged: true` → 调一次 `set_status %{id, status: "done"}`。

**Run**（期望）
```bash
mise exec -- mix ezagent.uri_query.scan                # 期望：with_action 构造过 gate
bash scripts/test-app.sh ezagent_plugin_github         # 期望：sync 4 测全绿
```

---

## Task 5 — kanban 去 github 化：连接器改 dispatch、删 github.ex/sync_prs/save_github_creds

**Files**
- 改 `apps/ezagent_plugin_kanban/lib/ezagent/behavior/kanban/connectors.ex`（sync_github/push_pr 改 dispatch；register_pr 去 token；删 sync_prs/save_github_creds/advance_merged_prs/push_ci_status/board_creds 的 token 部分）
- 改 `apps/ezagent_plugin_kanban/lib/ezagent/behavior/kanban.ex`（删 `action(:sync_prs)`/`action(:save_github_creds)` + required_caps 两条 + handle_* 两条 + get_tree 的 `github:` 字段 + `github_status/0`）
- **删** `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/github.ex`
- 改 `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/application.ex`（recipe `requested_caps` 自动随 `actions/0` 收缩，无需手改；确认无 `Github` 引用）
- 改 `apps/ezagent_plugin_kanban/mix.exs`（无需加 github 依赖——只 dispatch）
- 改 `apps/ezagent_plugin_kanban/test/behavior/relay_test.exs` + 涉 github 的测试

**Interfaces**（kanban→github 的 dispatch helper，加进 connectors.ex）
```elixir
@github_uri "entity://system/agent/github_gateway"
# 调 github gateway 出站动作（P14；plugin→plugin 不编译依赖，只 URI dispatch）。
defp gh(action, args, ctx) do
  target = Ezagent.URI.with_action(Ezagent.URI.new!(@github_uri), :github, action)
  Ezagent.Invocation.dispatch(%Ezagent.Invocation{
    target: target, mode: :call, args: args,
    ctx: %{caller: ctx[:caller], caps: ctx[:caps] || MapSet.new(), reply: {:caller_inbox, self()}}
  })
end
# repo 取本图配置（token 不再在 kanban；github gateway 自带 token）。
defp board_repo(ctx) do
  case ctx[:self_uri] do
    %URI{} = uri -> EzagentPluginKanban.BoardConfig.read(uri).github_repo
    _ -> nil
  end
end
```

**Steps**
1. **`sync_github`**（connectors.ex:31-70）：去 `Github.create_issue` 直调，改 `gh("create_issue", %{repo, title, body}, ctx)`；
   repo 取 `board_repo(ctx)`（nil → `:github_repo_missing`）；`{:ok, %{number, url}}` 回传后照旧
   `Shared.normalize_artifact` 挂 issue artifact + `Shared.commit`。授权闸（`Shared.owner_or_admin?`）不变。
2. **`push_pr`**（connectors.ex:75-112）：digest/verdict/gate_state 仍 `Ci.*` 本地算（**留 kanban**）；
   `node_pr(node)` 抠 PR 号不变；改：
   - `gh("get_pull", %{repo, number: pr}, ctx)` → sha；
   - `gh("post_comment", %{repo, number: pr, body: digest}, ctx)` → url；
   - `gh("create_commit_status", %{repo, sha, state: Ci.gate_state(verdict), context: "ezagent/ci-gate", description: "..."}, ctx)`。
   `push_ci_status/4`（connectors.ex:100）改成调 `gh` 的 best-effort 版（拿不到 sha/推失败 → `"skipped"`，
   语义不变）。返回 `{:ok, %{url, gate_state}, []}` 不变。
3. **`register_pr`**（connectors.ex:116-148）：**留 kanban**（board 写动作，github 轮询器 dispatch 它）。
   去 `board_creds`（token）依赖，repo 改 `board_repo(ctx)`；其余（`to_pr_number`、挂 pr artifact、commit）不变。
4. **删** `sync_prs`（connectors.ex:193-212）+ `advance_merged_prs`（:341-356）+ `done_node`（:358-363）+
   `push_ci_status` 里对 `Github` 的直引 + `board_creds`（:287-301）+ `gh_reason`（:370-375，搬去
   github plugin 后这里若仍需映射 dispatch 错误则保留精简版）+ `node_pr`（:316-327，push_pr 仍用 → 保留）。
   merged→done 语义已搬进 task 4 `Sync.advance_merged`。
5. **删** `save_github_creds`（connectors.ex:260-269）+ `kanban.ex` 对应 `action(:save_github_creds)`
   （kanban.ex:233-239）/ `handle_save_github_creds`（kanban.ex:691）/ `required_caps` 的 `:save_github_creds`
   （kanban.ex:280）。token 写盘归 github gateway `save_creds`。
6. **删** `action(:sync_prs)`（kanban.ex:201-207）/ `handle_sync_prs`（kanban.ex:682）/ `required_caps`
   的 `:sync_prs`（kanban.ex:276）。
7. **get_tree**（kanban.ex:558-575）：删 `github: github_status()`（kanban.ex:571）+ `github_status/0`
   （kanban.ex:601-611）+ `alias EzagentPluginKanban.Github`（connectors.ex:25 + kanban.ex 顶部若有）。
   `config: board_config(ctx)`（含 `github_repo` from BoardConfig）**保留**——repo 是一图配置、留 kanban。
8. **删文件** `apps/ezagent_plugin_kanban/lib/ezagent_plugin_kanban/github.ex`。
9. 改测试：`relay_test.exs` 的 `register_pr` 仍在 `@relay_actions`（kanban.ex:702 不变），断言不变；
   删任何引用 `EzagentPluginKanban.Github`/`sync_prs`/`save_github_creds` 的 kanban 测试；
   `sync_github`/`push_pr` 单测改用注入的 `gh` dispatch stub（断 dispatch target 是
   `entity://system/agent/github_gateway?action=github.create_issue` 等）。
10. **grep 自查**（task 收尾必跑，期望全 0）：
    ```bash
    git grep -n "EzagentPluginKanban.Github\|alias.*Github\|sync_prs\|save_github_creds\|create_commit_status\|list_open_pulls\|:httpc" apps/ezagent_plugin_kanban/lib   # 期望：0（github 代码已净身出 kanban）
    ```

**Run**（期望）
```bash
MIX_ENV=test mise exec -- mix ezagent.check_invariants.lifecycle
mise exec -- mix ezagent.arch.scan && mix ezagent.uri_query.scan
bash scripts/test-app.sh ezagent_plugin_kanban     # 期望：原 59→约 57 tests（减去 github 直测），0 failures, 7 excluded
bash scripts/test-app.sh ezagent_plugin_github     # 期望：仍绿
```

---

## Task 6 — world 接线重指向：save_github_creds / github 连接状态 → github gateway

**Files**
- 改 `apps/ezagent_plugin_world/lib/ezagent/world/kanban_actions.ex`（`kanban.save_github_creds` handler → dispatch github gateway `save_creds`；删 `kanban.sync_prs`/`kanban.attach_code_file`? — sync_prs 删，attach_code_file 留到 Phase 5）
- 改 `apps/ezagent_plugin_world/lib/ezagent/world/kanban_data.ex`（github 连接状态从 get_tree 的 `github:` 字段 → 改 dispatch github gateway `status`；kanban_data.ex:142 + :150）
- 改 `apps/ezagent_plugin_world/lib/ezagent_plugin_world/world_live.ex`（`@kanban_actions` 删 `kanban.sync_prs`、`kanban.save_github_creds` 改路由到 github，world_live.ex:242）
- 改对应 world 测试

**Interfaces**
- world 的 github 出站统一经 `Ezagent.URI.with_action(EzagentPluginGithub.Application.gateway_uri(), :github, action)` dispatch
  （world→plugin dispatch 允许；world 已 dispatch kanban，加一条 github 同理）。
- 前端连接器面板的 github 状态从 `get_tree` 结果剥离后，改一条独立 dispatch `github.status` 取
  `%{configured, repo}`。

**Steps**
1. `kanban_actions.ex:118-126`（`kanban.save_github_creds`）：handler 改 dispatch github gateway
   `save_creds %{access_token, repo}`（admin-gated 由 gateway handle_save_creds 内判）。
2. `kanban_actions.ex:144-145`（`kanban.sync_prs`）：**删**（merged→done 已由 github 轮询器自动）。
3. `kanban_data.ex:142`/`:150`（`"github" => jsonable_status(...)`）：改成独立 dispatch `github.status`
   填 `%{"configured" => ..., "repo" => ...}`；get_tree 不再带 github 字段（task 5 已删后端）。
4. `world_live.ex:242` `@kanban_actions`：删 `kanban.sync_prs`；`kanban.save_github_creds` 保留路由名
   但 handler 转发到 github（前端 UI 不动，只换后端落点）。
5. 改 world 测试：断 `save_github_creds` 落到 github gateway dispatch；断连接状态 dispatch `github.status`。
6. **截图**（agent-browser，remote `100.64.0.27`）：Plugins→kanban 板→连接器面板填 github token+repo→保存
   →状态显示 configured。每步截图。

**Run**（期望）
```bash
bash scripts/test-app.sh ezagent_plugin_world      # 期望：world kanban 测绿
mise exec -- mix format --check-formatted apps/ezagent_plugin_world/lib/ezagent/world/kanban_actions.ex apps/ezagent_plugin_world/lib/ezagent/world/kanban_data.ex
```

---

## Task 7 — 真 test-ezagent repo E2E 自动 CI 闭环 + 全 gate

**Files**
- 新建 `apps/ezagent_plugin_github/test/integration/auto_ci_loop_test.exs`（`@tag :live_github`，默认 excluded，仿 kanban `:live_miro`）
- 新建 `docs/together/2026-06-26/github-phase2/` 截图目录（e2e 存证）

**Interfaces / E2E 剧本**（真 repo `test-ezagent`，github token 经 `github.save_creds` 写入）
1. 建 board（kanban-as-role agent）+ `set_board_config %{github_repo: "<owner>/test-ezagent"}` →
   kanban dispatch github gateway `bind_repo` → 起 per-board `Sync` 轮询器（截图：board + 配置）。
2. 在 GitHub 开一个 PR，分支名含目标 issue 节点 id（如 `task/<node_id>-foo`）。
3. 等一个轮询 tick（或 `Sync.sync_now`）→ **自动 `register_pr`**：节点挂 `kind="pr"` artifact（截图：节点出现 PR 徽章）。
4. `push_pr`（world 操作或 dispatch）→ github gateway `post_comment`（PR 出现 ezagent 需求摘要评论）+
   `create_commit_status`（PR 出现 `ezagent/ci-gate` 红/绿 status check）（截图：PR 页评论 + status）。
5. 在 GitHub 合并该 PR → 下一 tick `Sync.advance_merged` → **自动 `set_status done`**（截图：节点 done）。

**Steps**
1. 写 `auto_ci_loop_test.exs`（`:live_github`）：用真 token + 真 repo，跑步骤 1-5 的机械链断言
   （open PR 出现后 `get_tree` 节点有 pr artifact；合并后节点 status==done）。无真凭证时 excluded。
2. 跑全 gate：
   ```bash
   MIX_ENV=test mise exec -- mix ezagent.check_invariants.lifecycle
   mise exec -- mix ezagent.arch.scan
   mise exec -- mix ezagent.uri_query.scan
   mise exec -- mix format --check-formatted
   bash scripts/test-app.sh ezagent_plugin_github
   bash scripts/test-app.sh ezagent_plugin_kanban
   bash scripts/test-app.sh ezagent_plugin_world
   ```
3. 真 e2e（带 `--include live_github`）跑一遍 + 全程截图存 `docs/together/2026-06-26/github-phase2/`。
4. commit（commit-work skill；Co-Authored-By 收尾）。

**Run**（期望）
```bash
# 真凭证下：
MIX_ENV=test mise exec -- mix test apps/ezagent_plugin_github/test/integration/auto_ci_loop_test.exs --include live_github
# 期望：open PR→自动 register（节点挂 pr）→push_pr 自动 status→merge→自动 done，全链路 0 人手填
```

---

## Self-Review

**覆盖 SPEC §6/§7 Phase 2 验收**
- [x] github 全部 in+out 从 kanban 抽进 `ezagent_plugin_github`（task 2 出站客户端 / task 3 出站
      Behavior gateway / task 4 入站轮询 / task 5 kanban 净身 + 删 github.ex）。
- [x] kanban 只留 CI 判据计算（`Ci.check_pr_gate`/`gate_state`/`requirement_digest` 全不动，task 5
      `push_pr` 仍本地算，只把 HTTP 那 3 步 dispatch 给 github）。
- [x] github token 归新 plugin（task 2 `Client.read_creds`/`write_creds` + task 3 `save_creds`；
      kanban grep token=0，task 5 step 10）。
- [x] kanban↔github 全程 `Invocation.dispatch`（task 5 `gh/3` helper + task 4 `dispatch_kanban`，
      `with_action` 构造过 uri_query gate）。
- [x] 入站自动化（轮询 list PRs 按 head_ref 匹配→自动 register_pr；merged→自动 done），仿 MiroSync
      plugin 自有进程、不复用 external_mirror 域、幂等（task 4）。
- [x] register_pr 仍是 `@relay_actions`（kanban.ex:702 不动）→ 自动登记触发 B1 接力唤醒（为 Phase 3 留口）。

**三层铁律 / 不变式自查**
- [x] core 不碰：新增全在 `apps/ezagent_plugin_github` + `apps/ezagent_plugin_kanban` + `apps/ezagent_plugin_world`。
- [x] plugin→plugin 无编译依赖：kanban 不 `alias` github（只 dispatch URI）；github 不 `alias` kanban。
- [x] P14：无 `PubSub.broadcast` 到 inbound；全 `Invocation.dispatch`。
- [x] Behavior 只 `use Ezagent.Lifecycle`（task 3 github Behavior，无 `use Ezagent.Behavior`/`invoke/4`；
      lifecycle gate 把关）。
- [x] P22 可靠性：入站幂等（Idempotency）+ dispatch 失败不静默丢。

**风险 / 待确认（开工逐项核）**
- gateway 宿主 role×native vs own-Kind：task 3 开工前确认 `Workspace.create_agent/3` 的 args 键名 +
  native flavor seed 路（对 `kanban_role_test.exs` + `workspace.ex:760` 核），二选一不碰 core（设计 checkpoint，非 E 类等 Allen）。
- 分支名→节点匹配（`String.contains?(head_ref, id)`）是 Phase 2 约定，依赖 dev-together per-task 分支
  编码节点 id（Phase 3 落实命名）；约定不齐则轮询匹配不上——写进 `Sync` moduledoc 显式声明。
- 已存在 board 的 `bind_repo`：Phase 2 靠 `set_board_config` 再写一次触发；存量板需手动 re-config
  一次（或运维一次性 dispatch），文档注明。
- 多仓库（SPEC §5）+ webhook 实时化 = Phase 4，**本计划不做**（轮询先拔人工断点）。
- `attach_code_file` 仅读 repo（无 github 出站），**保留**到 Phase 5 删（flow-redesign §3）；本计划不动。

**测试基线对照**：kanban 现 59t/7excl（skill-1 实跑）；task 5 后预计 ~57t（减 github 直测）+ github
新 app ~10t（client/behavior/seed/sync）+ 真 repo `:live_github` 1 集成（默认 excluded）。
