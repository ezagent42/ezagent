defmodule EzagentPluginGithub.Application do
  @moduledoc """
  GitHub 通用插件 OTP app + `Ezagent.Plugin` 契约模块。

  本插件是**通用 github 网关**：经 `gh` CLI（`System.cmd("gh", …)`，sanctioned——
  arch gate 只禁 raw `Port.open({:spawn_executable, …})`）暴露 github 能力，可被任何
  plugin/agent 经 `Ezagent.Invocation.dispatch/1` 复用（kanban 只是消费者）。

  token 可配置（Miro 式）：用户凭证写 `system://credentials/github.yaml`，调 gh 时经
  `env: [{"GH_TOKEN", token}]` 覆盖；没配则走 gh 自带 auth（debug default）。

  ## 网关 = 一个系统单例 agent（role × native，懒种）

  出站能力以 `Ezagent.Behavior.Github`（薄包 `Gh.*`）暴露，挂在系统单例 gateway agent
  （`entity://system/agent/github_gateway`）上：flavor `native`（boot 注册的通用宿主）×
  role `github-gateway`（本 `roles/0` 声明的 recipe，框架 boot 经 `RoleRegistry.register/1`
  登记）。消费者经 `github.<action>` dispatch 到该 agent（同 kanban-as-role 范式）。

  **懒种（不在 boot 种）**：gateway agent 在**首次 dispatch 前**由消费者
  （kanban `gh/3`）经 `Ezagent.Workspace.create_agent` 确保起活（已起活幂等 / 有快照
  rehydrate / 从未创建则建），仿 kanban-manager 经 `KanbanData.ensure_spawned/1` 的懒种
  先例。这样种子跑在节点全 up 之后——无 boot 竞态、无"漏种到下次 boot"窗口，本插件也
  无需任何 domain/plugin 运行时依赖（仍是纯 plugin：core + jason）。

  ## 纯 plugin（路 A）

  声明 `plugin_info/0` / `roles/0` / `children/0`（PrSync 入站轮询监督基建），其余
  callback 走 `use Ezagent.Plugin` 的 `defoverridable` 默认（`behaviors/0 → []`：网关
  behavior 经 role per-instance 加载，不走静态 `behaviors/0`；`after_boot/0 → :ok`：
  不在 boot 种）。

  ## 入站：open-PR 轮询（PrSync）

  `EzagentPluginGithub.PrSync` 周期轮询 repo 的 open PR，按分支名约定（`kanban/<node_id>`）
  解析出 kanban 节点 → 系统身份 dispatch 回 `kanban.register_pr`（跨插件零编译依赖）。
  其监督基建（Registry + DynamicSupervisor）由本 `children/0` 声明、框架 boot 起；**boot
  不主动轮询任何板**——由编排层按板 `PrSync.bind/3`（仿 kanban MiroSync supervision）。
  """

  use Application
  use Ezagent.Plugin

  alias Ezagent.Behavior.Github, as: GithubBehavior

  # gateway 的 role / 寻址（系统单例；消费者懒种用同一对 role/name）。
  @gateway_role "github-gateway"
  @gateway_name "github_gateway"

  @impl Application
  def start(_type, _args), do: Ezagent.Plugin.boot(__MODULE__)

  @impl Ezagent.Plugin
  def plugin_info do
    %{
      slug: "github",
      name: "GitHub",
      description: "GitHub 通用网关（经 gh CLI）：issue / PR 评论 / commit status / open PR 列表。",
      version: "0.1.0"
    }
  end

  # github-gateway role recipe（kanban-as-role 范式）：
  #   * `behaviors: [Ezagent.Behavior.Github]` —— 网关 behavior（6 动作经 role
  #     per-instance 挂通用 `Entity.Agent` 宿主）。
  #   * `passive: true` —— 网关是被动出站 actor：不可被 @ / 不可 `:join` / 不收 chat，
  #     只在直接 `github.<action>` dispatch 上动作。
  #   * `requested_caps` = 每个动作一个 cap-template map `%{behavior:, action:}`
  #     （不带 kind——kind 由 native flavor 的 CapMint 按 flavor 注入 `:agent`）。
  @impl Ezagent.Plugin
  def roles, do: [github_gateway_recipe()]

  @doc """
  The `github-gateway` role recipe（也是 role 测试的主语）。

  Public 让 role 测试断言确切 recipe 而不重导出动作列表（单一真相源 =
  `Ezagent.Behavior.Github.actions/0`）。
  """
  @spec github_gateway_recipe() :: map()
  def github_gateway_recipe do
    %{
      name: @gateway_role,
      passive: true,
      behaviors: [GithubBehavior],
      requested_caps:
        for action <- GithubBehavior.actions() do
          %{behavior: GithubBehavior, action: action}
        end
    }
  end

  @doc "gateway agent 的 URI（系统单例）：`entity://system/agent/github_gateway`。"
  @spec gateway_uri() :: Ezagent.URI.t()
  def gateway_uri, do: Ezagent.URI.agent(:system, @gateway_name)

  # PrSync open-PR 入站轮询的监督基建（仿 kanban MiroSync supervision）：按 kanban URI
  # 唯一注册的 Registry + DynamicSupervisor 下动态起停 poller。boot 不主动轮询任何板
  # （按板 `PrSync.bind/3`，无 boot 竞态）。
  @impl Ezagent.Plugin
  def children do
    [
      {Registry, keys: :unique, name: EzagentPluginGithub.PrSyncRegistry},
      {DynamicSupervisor, name: EzagentPluginGithub.PrSyncSupervisor, strategy: :one_for_one}
    ]
  end
end
