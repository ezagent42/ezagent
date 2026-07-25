defmodule EzagentPluginHello.Integration.HelloGreeterRelayReproTest do
  @moduledoc """
  Regression for the hello 官网 greeter-relay crash (#1457 cap-signing).

  A member `:send` to the hello greeter is delivered to the front-desk agent as a
  genuine runtime `:receive`. The `"hello"` flavor is `:in_process_sync`, so
  `Agent.Receive` re-dispatches the message into the flavor's per-instance
  `:hello_sync_result` action — and to do so it mints a target-signed self-cap via
  `Ezagent.Cap.issue_for_action/3` (`receive.ex`).

  Before the fix, `Cap.action_context/3`'s SELF-target branch resolved the action
  ONLY through the GLOBAL `BehaviorRegistry`. `:hello_sync_result` is a flavor-only,
  PER-INSTANCE action (mounted via the hello role recipe, NOT globally registered
  like py's `:py_sync_result`), so the global lookup returned `:error` →
  `{:error, {:unknown_action, :hello_sync_result}}` → the `{:ok, signed_cap} = …`
  BADMATCH crashed `Agent.Receive.handle_receive/2` and the visitor's message was
  stored but never answered.

  This drives the GENUINE runtime `:receive` via the real per-recipient delivery
  primitive `Ezagent.ActionSet.Session.Delivery.dispatch_receive_call/3` (which does
  the real `Router.dispatch` of `:receive` and fires the sync-result re-dispatch —
  unlike `hello_orchestrator_delivery_test.exs`, which stops at
  `deliver_agent_receive`). The relay must complete WITHOUT the
  `{:unknown_action, :hello_sync_result}` badmatch.

  Keyless by design (`DEEPSEEK_API_KEY` cleared): the only acceptable downstream
  stop is the concierge's LLM call failing `{:no_api_key, "deepseek"}` — that is
  PAST the resolver and is not a crash.
  """
  use EzagentCore.DataCase, async: false

  import ExUnit.CaptureLog

  alias Ezagent.ActionSet.Session.Delivery
  alias Ezagent.Agent.RecipeRegistry
  alias Ezagent.{KindRegistry, Message, Workspace}
  alias EzagentPluginHello.App
  alias EzagentPluginHello.Application, as: HelloApp

  setup do
    :ok = EzagentPluginHello.TestCatalog.import!()
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_agent)
    {:ok, _} = Application.ensure_all_started(:ezagent_plugin_curl_agent)
    {:ok, _} = Application.ensure_all_started(:ezagent_plugin_kanban)

    Enum.each(HelloApp.roles(), fn recipe ->
      {:ok, _} = RecipeRegistry.seed_role_if_absent(recipe)
    end)

    # The relay must resolve WITHOUT any real LLM key; clear it so a pass proves
    # the resolver+cap path, not an ambient credential.
    prev_key = System.get_env("DEEPSEEK_API_KEY")
    System.delete_env("DEEPSEEK_API_KEY")
    on_exit(fn -> if prev_key, do: System.put_env("DEEPSEEK_API_KEY", prev_key) end)

    :ok
  end

  test "greeter relay: member :receive re-dispatches :hello_sync_result without crash" do
    ws = "hello-relay-#{System.unique_integer([:positive])}"
    {:ok, _} = Workspace.create(ws, %{})
    {:ok, session_uri, front_desk_uri} = App.ensure_app(ws, "web")

    # Revive the front-desk (same as the real delivery primitive does) so we hold
    # a live pid to use as a synchronous mailbox barrier.
    _ = Ezagent.Domain.Agent.ensure_deliverable(front_desk_uri)
    {:ok, front_desk_pid} = KindRegistry.lookup(URI.to_string(front_desk_uri))

    sender = Ezagent.URI.entity(ws, :user, "visitor")
    msg = Message.new(sender, %{text: "hello there greeter", attachments: []})

    log =
      capture_log(fn ->
        # GENUINE runtime receive: real Router.dispatch of :receive to the
        # front-desk. The self-cap for :hello_sync_result is minted synchronously
        # INSIDE this dispatch (Agent.Receive builds the sync_result effect), so
        # the badmatch — if present — is emitted before the barrier below returns.
        _ = Delivery.dispatch_receive_call(front_desk_uri, msg, session_uri)

        # Deterministic drain: a synchronous system message is FIFO-ordered behind
        # the :receive cast (and behind the deferred post-commit :hello_sync_result
        # cast, which also lands in THIS agent's mailbox), so once these return the
        # front-desk has processed both hops and any crash log has been emitted.
        drain_mailbox(front_desk_pid)
      end)

    # The invariant this whole fix exists for: the self-target re-dispatch of the
    # flavor-only :hello_sync_result action resolves, so no badmatch crash.
    refute log =~ "unknown_action, :hello_sync_result",
           "greeter relay crashed on the self-target resolver:\n#{log}"

    refute log =~ "handle_receive/2 crashed",
           "Agent.Receive.handle_receive/2 crashed during the relay:\n#{log}"

    # The relay's front-desk process must survive the whole hop (the crash was
    # caught-and-logged pre-fix, so liveness alone never proved correctness —
    # the log assertions above are the real gate; this is a sanity guard).
    assert Process.alive?(front_desk_pid)
  end

  # Three synchronous barriers: the first flushes the :receive dispatch, the rest
  # flush the deferred post-commit :hello_sync_result self-dispatch (both are casts
  # to THIS agent's mailbox). `:sys.get_state/1` is a synchronous system message,
  # so FIFO ordering guarantees the preceding casts ran before it returns — no
  # sleeps, no flake.
  defp drain_mailbox(pid) do
    Enum.each(1..3, fn _ -> _ = :sys.get_state(pid) end)
  end
end
