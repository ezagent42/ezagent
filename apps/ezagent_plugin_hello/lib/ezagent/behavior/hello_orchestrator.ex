defmodule Ezagent.ActionSet.HelloOrchestrator do
  @moduledoc """
  The hello FRONT-DESK agent Behavior — the invisible per-session chat relay.

  Every user message in a hello session is delivered to THIS agent (the routing
  rule `{:always} -> ["front-desk"]`). Chat arrives on the `"hello"` FLAVOR's
  in-process AgentBridge adapter (`EzagentPluginHello.BridgeAdapter`), which
  `Agent.Receive` re-dispatches into this behaviour's `:hello_sync_result` action.
  The handler hands the message off to `EzagentPluginHello.Router`, which decides
  — per message, by intent × identity — whether to DISPATCH `:rebuild` to the
  page builder or `:answer` to the read-only concierge (both native-flavor — they
  receive via dispatch, not chat delivery, per T2 I-1).

  The platform orchestrator (`requires: ["orchestrator"]`, cc flavor) handles
  team management (template ops, member management). This agent handles ONLY
  per-message routing — it is the chat→dispatch relay.

  ## Why `:hello_sync_result`, not `:receive`

  `:receive` on `Entity.Agent` is owned by the flavor-blind `Agent.Receive` (the
  AgentBridge seam) and cannot be overridden by a role behaviour. The supported way
  for an in-process flavor to run custom Elixir on chat is the `:in_process_sync`
  class: the adapter returns the message inputs, `Agent.Receive` re-dispatches them
  to the flavor behaviour's `:sync_result`. That is this action.

  Loop-safe + multi-agent by construction: `Agent.Receive` drops the agent's own
  outbound before delivery, and `EzagentPluginHello.Router.should_route?/2`
  additionally ignores any message whose sender is the front-desk itself or one
  of its own builder/concierge workers — so the front-desk routes every OTHER
  sender (users AND external agents) without ever re-routing its own workers.

  It is a `hello.front-desk` role on the unified `Ezagent.Entity.Agent`, hosted by
  the `"hello"` flavor. `create/1` stores `flavor: "hello"` so the delivery flavor
  resolves from the durable snapshot after a cold restart.
  """

  use Ezagent.Lifecycle

  # `:hello_sync_result`, NOT the default `:sync_result` — the latter is claimed
  # GLOBALLY by `Behavior.CurlAgent` on `Entity.Agent`, so it resolves to curl (not
  # in this instance's set) and is denied. `Agent.Receive.sync_result_action("hello")`
  # maps the `"hello"` flavor's chat re-dispatch to this action (mirrors py/cc-headless).
  action(:hello_sync_result,
    # `result` is the `"hello"` adapter's `{:ok, %{session_uri, sender, text}}` (or
    # `{:ok, :ignored}`) — a structurally-varied tuple this handler matches itself.
    args: %{result: :term, source_session: {:option, :uri}, user_text: :string},
    returns: %{},
    caps: [:hello_sync_result],
    modes: [:cast],
    description: "Route an inbound chat message to the page builder or read-only concierge"
  )

  @impl Ezagent.Lifecycle
  def create(_args), do: {:ok, %{flavor: "hello"}}

  @doc """
  Hand the delivered message off to the Router (fire-and-forget). No-op for the
  blank/ignored case or any unexpected shape — never crash the delivery.
  """
  def handle_hello_sync_result(
        %{
          result: {:ok, %{session_uri: %URI{} = session_uri, sender: %URI{} = sender, text: text}}
        },
        _ctx
      )
      when is_binary(text) do
    _ = EzagentPluginHello.Router.route(session_uri, text, sender)
    {:ok, %{}, []}
  end

  def handle_hello_sync_result(_args, _ctx), do: {:ok, %{}, []}

  # caps-data-ownership — admin-only Behavior; no per-entity owner.
  def data_owner(:any), do: :any
  def data_owner(_), do: :no_owner
end
