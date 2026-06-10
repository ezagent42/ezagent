defmodule EzagentPluginEmPull.PullAdapterAllow do
  @moduledoc "Cap-only Allow Behavior paired (by convention) with the pull adapter."
  @behaviour Ezagent.Behavior

  @impl true
  def actions, do: [:allow_em_pull]

  @impl true
  def cap_subjects, do: [{:allow_em_pull, "Authorize the em_pull pull adapter."}]

  @impl true
  def dispatchable?, do: false

  @impl true
  def state_slice, do: :external_adapter_em_pull

  @impl true
  def init_slice(_args), do: %{}

  @impl true
  def invoke(_action, _slice, _args, _ctx), do: raise("cap-only")

  @impl true
  def interface, do: %{}

  @impl true
  def data_owner(_), do: :any
end

defmodule EzagentPluginEmPull.PullAdapter do
  @moduledoc """
  A valid binding-less `:pull` Adapter — positive control for the P3-1
  bare-module declaration branch of the `:ezagent_plugin_check` gate.

  Declares `adapter_kind/0 == :pull`, `render/2`, and `cap_subject/0`,
  but NO `binding_module/0` (pull adapters have no binding).
  """
  @behaviour Ezagent.ExternalMirror.Adapter

  @impl true
  def adapter_id, do: "em_pull"

  @impl true
  def display_name, do: "EM Pull"

  @impl true
  def description, do: "Positive control pull adapter for the P3-1 gate."

  @impl true
  def adapter_kind, do: :pull

  @impl true
  def cap_subject do
    %{
      behavior_module: EzagentPluginEmPull.PullAdapterAllow,
      description: "Pull adapter allow cap."
    }
  end

  @impl true
  def render(%URI{} = session_uri, ctx) when is_map(ctx) do
    %{session_uri: URI.to_string(session_uri), ctx: ctx}
  end
end

defmodule EzagentPluginEmPull do
  @moduledoc """
  A CONFORMING plugin declaring ONE binding-less `:pull` ExternalMirror
  adapter as a BARE module — positive control for the P3-1 pull branch
  of the `:ezagent_plugin_check` Grill-5 gate.
  """
  use Ezagent.Plugin

  @impl Ezagent.Plugin
  def plugin_info do
    %{
      slug: "em-pull",
      name: "EM Pull Fixture",
      description: "Positive control for the P3-1 pull-adapter gate.",
      version: "0.1.0"
    }
  end

  @impl Ezagent.Plugin
  def adapters do
    [EzagentPluginEmPull.PullAdapter]
  end
end
