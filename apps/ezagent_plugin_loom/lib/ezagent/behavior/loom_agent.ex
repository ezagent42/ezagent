defmodule Ezagent.Behavior.LoomAgent do
  @moduledoc """
  Loom agent Behavior —— loom **编排控制器**作为 socialware Session Member 的最小载体。

  loom session 创建时建一队这种 Kind(orchestrator / v0 / worker / meta / stitch),
  `session.join` 后出现在 admin Members 面板(read_session_members 读 session `:members` slice,
  而 `session.join` 要求 member 是活 Kind —— 故必须有这个真 Kind)。

  ## 边界(2026-06-17 Allen 决策)

  编排控制器**留在 loom 自己实现**(socialware/ezagent 无对应);但**调 LLM 统一走
  `EzagentPluginLoom.LLM`**(已对接 socialware/ezagent:curl_agent ApiClient + provider/凭证/flavor)。
  本 Kind 是 Member 载体 + role 元数据;编排逻辑在 `EzagentPluginLoom.OrchestratorServer`
  (控制器,loom 内部),按 role 归因 LLM 调用。

  role 由 agent URI 名前缀携带(`loomorch_` / `loomv0_` / `loomworker_…` / `loommeta_` /
  `loomstitch_`),同 loom-stitch;`:role` slice 冗余存一份便于 `:describe`。
  """

  use Ezagent.Lifecycle

  action(:describe,
    args: %{},
    returns: %{role: :string},
    caps: [:describe],
    modes: [:call],
    description: "Return this loom agent's role label"
  )

  # kind 轴 = :loom_agent(覆盖宏的 :any 默认,同 Echo 做法)。
  def required_caps do
    %{describe: Ezagent.Capability.cap(:loom_agent, __MODULE__, :describe)}
  end

  # 自动派生 slice key = 末段 LoomAgent → :loom_agent。
  @impl Ezagent.Lifecycle
  def create(args) when is_map(args), do: {:ok, %{role: role_of(args)}}
  def create(_), do: {:ok, %{role: nil}}

  def handle_describe(_args, ctx) do
    {:ok, %{role: ctx[:read].(:role, nil) || ""}, []}
  end

  defp role_of(args) do
    Map.get(args, :role) || Map.get(args, "role")
  end
end
