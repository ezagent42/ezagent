defmodule EzagentPluginHello.BridgeAdapter do
  @moduledoc """
  The `"hello"` agent-flavor AgentBridge adapter — the seam that lets a hello
  agent (the orchestrator) RECEIVE chat and run custom Elixir.

  ## Why hello needs its own flavor

  On the unified `Ezagent.Entity.Agent`, `:receive` (the session chat fan-out hook)
  is hardwired to `Ezagent.ActionSet.Agent.Receive`, which hands DOWN to a
  per-flavor `AgentBridge` adapter. `native` has NO adapter, so a native agent's
  chat is dropped (`:no_sandbox_respawn_state`) and a role behavior's own
  `:receive` never runs. So the orchestrator can't be a `native` role agent — it
  is a role × `"hello"` flavor agent, and THIS adapter is what `Agent.Receive`
  routes its chat into.

  ## Transport class — `:in_process_sync` (mirrors `curl`)

  `deliver/2` runs SYNCHRONOUSLY inside the agent's dispatch with the full
  `Payload` (session + sender + text). It does no work itself — it just returns
  those inputs as `{:ok, %{…}}`. `Agent.Receive` re-dispatches that result into the
  agent's `:sync_result` action (`Ezagent.ActionSet.HelloOrchestrator`), which hands
  it to `EzagentPluginHello.Router` (fire-and-forget). Extraction here, routing in
  the behavior — the same split curl uses (adapter does the round-trip, the
  behaviour persists).
  """

  @behaviour Ezagent.AgentBridge.Adapter

  alias Ezagent.AgentBridge.Payload

  @impl Ezagent.AgentBridge.Adapter
  def flavor, do: "hello"

  @impl Ezagent.AgentBridge.Adapter
  def transport_class, do: :in_process_sync

  @impl Ezagent.AgentBridge.Adapter
  def deliver(
        %Payload{session_uri: %URI{} = session_uri, sender_uri: sender, text: text, meta: meta},
        _ref
      )
      when is_binary(text) and text != "" do
    {:ok,
     %{
       session_uri: session_uri,
       sender: sender,
       text: text,
       ref_id: Map.get(meta, "ref_id")
     }}
  end

  # Blank text / missing session → nothing to route (the behaviour no-ops on it).
  def deliver(%Payload{}, _ref), do: {:ok, :ignored}
end
