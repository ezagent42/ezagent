defmodule EzagentDomainChat.Integration.OrchestratorMcpReregisterTest do
  @moduledoc """
  Invariant test for Task #110 — the orchestrator MCP context must be
  RE-registered when a Session Kind cold-loads from its snapshot after a
  phx restart, so the orchestrator's `orch:bridge:<uri>` channel join
  succeeds (and its 7 management MCP tools work) WITHOUT requiring a
  fresh session re-spawn.

  ## The bug

  `Ezagent.Orchestrator.McpRegistry` is an in-memory ETS table
  (orchestrator URI → `(session_uri, workspace_uri, owner_uri,
  parent_template_uri)`). The Generator writes the row ONLY at
  session-spawn time (`Ezagent.Entity.Session` step 7). On a phx restart
  the Session Kind cold-loads from `kind_snapshots`, but the Generator
  path never re-runs, so the ETS row is gone —
  `McpServer.from_orchestrator_uri/1` then fail-closes every bridge join
  with `{:error, :orchestrator_not_registered}`.

  ## The gate

  This test simulates a cold-load (`Snapshot.save_now` a populated
  `:chat` slice → respawn the Session Kind) and asserts
  `McpRegistry.lookup(orchestrator_uri)` returns `{:ok, ctx}` afterward
  with the recovered session / workspace / owner / parent-template URIs.

  Pre-fix (`Behavior.Chat` had no `on_ready/2`), the lookup returns
  `:error` after the respawn — the assertion fails. Per memory
  `feedback_completion_requires_invariant_test` this is the gate that
  fails the moment the re-registration regresses.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{Capability, KindRegistry}
  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.Behavior.Chat
  alias Ezagent.Entity.Session
  alias Ezagent.Kind.Snapshot
  alias Ezagent.Orchestrator.McpRegistry

  defp unique_session_uri do
    URI.parse(
      "session://default/team-alpha/owner-mcp-reregister-#{System.unique_integer([:positive])}"
    )
  end

  # Build a Session :chat slice that carries an orchestrator-backed
  # template_working_copy — exactly the shape the Generator persists
  # (template-SHAPED working copy + the Task #110 :session_template_uri).
  defp orchestrator_chat_slice(opts) do
    %{
      members: %{},
      monitors: %{},
      last_seen: %{},
      owner_uri: Keyword.fetch!(opts, :owner_uri),
      template_working_copy: %{
        agent_slots: [],
        routing_rules: [],
        orchestrator_template_uri:
          URI.parse("template://agent/system/cc-orchestrator"),
        session_template_uri: Keyword.fetch!(opts, :session_template_uri),
        default_workspace_uri: URI.parse("workspace://default"),
        description: "task #110 fixture"
      }
    }
  end

  defp spawn_session(session_uri) do
    {:ok, pid} = Ezagent.Kind.spawn(Session, %{uri: session_uri})
    pid
  end

  defp wait_until(fun, attempts \\ 50)
  defp wait_until(_fun, 0), do: flunk("wait_until: condition never became true")

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      wait_until(fun, attempts - 1)
    end
  end

  describe "orchestrator MCP context survives a Session cold-load — THE GATE" do
    test "an orchestrator-backed session re-registers its MCP context on respawn" do
      session_uri = unique_session_uri()
      uri_str = URI.to_string(session_uri)

      owner_uri = URI.parse("entity://user/default/owner-mcp")
      session_template_uri = URI.parse("template://session/default/owner-mcp-team")

      workspace_uri = Capability.workspace_of(session_uri)
      orchestrator_uri = Session.derive_orchestrator_uri(session_uri, workspace_uri)

      # Clean slate — no stale snapshot, no stale ETS row from a prior run.
      :ok = KindSnapshot.delete(uri_str)
      :ok = McpRegistry.unregister(orchestrator_uri)

      # Persist a snapshot as if the Generator had run + the BEAM then
      # crashed (the in-memory McpRegistry row is gone — assert that).
      chat_slice =
        orchestrator_chat_slice(
          owner_uri: owner_uri,
          session_template_uri: session_template_uri
        )

      :ok = Snapshot.save_now(session_uri, Session, %{chat: chat_slice})
      assert McpRegistry.lookup(orchestrator_uri) == :error

      # Cold-load the Session Kind from the snapshot (the phx-restart
      # rehydrate path). NOTHING re-runs the Generator.
      _pid = spawn_session(session_uri)

      # The fix: Chat.on_ready/2 re-registers the orchestrator MCP
      # context. on_ready fires AFTER ReadyGate flips, so allow the
      # continue to drain.
      wait_until(fn -> match?({:ok, _}, McpRegistry.lookup(orchestrator_uri)) end)

      assert {:ok, ctx} = McpRegistry.lookup(orchestrator_uri),
             "orchestrator MCP context was NOT re-registered after a Session " <>
               "cold-load — Behavior.Chat.on_ready/2 must re-register so the " <>
               "orch:bridge join succeeds without a fresh re-spawn (Task #110)"

      assert URI.to_string(ctx.session_uri) == uri_str
      assert URI.to_string(ctx.workspace_uri) == URI.to_string(workspace_uri)
      assert URI.to_string(ctx.owner_uri) == URI.to_string(owner_uri)

      assert URI.to_string(ctx.parent_template_uri) ==
               URI.to_string(session_template_uri),
             "parent_template_uri must be recovered from the durable " <>
               "template_working_copy.session_template_uri so the " <>
               "update_template MCP tool works after restart"
    end

    test "re-running the cold-load re-registration is idempotent (no crash, same row)" do
      session_uri = unique_session_uri()
      owner_uri = URI.parse("entity://user/default/owner-idem")
      session_template_uri = URI.parse("template://session/default/owner-idem-team")

      workspace_uri = Capability.workspace_of(session_uri)
      orchestrator_uri = Session.derive_orchestrator_uri(session_uri, workspace_uri)

      :ok = KindSnapshot.delete(URI.to_string(session_uri))
      :ok = McpRegistry.unregister(orchestrator_uri)

      chat_slice =
        orchestrator_chat_slice(
          owner_uri: owner_uri,
          session_template_uri: session_template_uri
        )

      ctx = %{self_uri: session_uri, kind_module: Session}

      # Calling on_ready twice (cold-load + a hypothetical re-ready) must
      # produce the same single row — ETS put is naturally idempotent.
      assert :ok = Chat.on_ready(chat_slice, ctx)
      assert :ok = Chat.on_ready(chat_slice, ctx)

      assert {:ok, recovered} = McpRegistry.lookup(orchestrator_uri)
      assert URI.to_string(recovered.session_uri) == URI.to_string(session_uri)
    end
  end

  describe "no-op for sessions without an orchestrator" do
    test "a plain session (no orchestrator_template_uri) does NOT register anything" do
      session_uri = unique_session_uri()
      workspace_uri = Capability.workspace_of(session_uri)
      orchestrator_uri = Session.derive_orchestrator_uri(session_uri, workspace_uri)

      :ok = KindSnapshot.delete(URI.to_string(session_uri))
      :ok = McpRegistry.unregister(orchestrator_uri)

      # A fresh / system session: template_working_copy keeps the
      # default shape where :orchestrator_template_uri is nil.
      plain_slice = %{
        members: %{},
        monitors: %{},
        last_seen: %{},
        owner_uri: nil,
        template_working_copy: Chat.default_template_working_copy()
      }

      :ok = Snapshot.save_now(session_uri, Session, %{chat: plain_slice})
      _pid = spawn_session(session_uri)

      # Give on_ready a chance to run; it must NOT register.
      Process.sleep(100)
      assert KindRegistry.lookup(session_uri) != :error

      assert McpRegistry.lookup(orchestrator_uri) == :error,
             "a session with no orchestrator must be a clean no-op — " <>
               "on_ready must guard on orchestrator_template_uri presence"
    end
  end
end
