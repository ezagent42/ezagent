defmodule EzagentDomainInstanceMessage.Integration.OrchestratorPrestoreReadinessTest do
  @moduledoc """
  Regression for the 2026-06-15 live-create orchestrator-readiness deadlock
  (`docs/notes/2026-06-15-live-orchestrator-mcp-registration-bug.md`).

  On a fresh create the durable session→orchestrator binding was written only
  at step 6 (`Materializer.store_session_orchestrator_uri/2`), which runs AFTER
  the step-5 readiness gate. But the gate POLLS for the live orchestrator's MCP
  bridge join, and that join self-registers by reading the durable binding
  (`Ezagent.Orchestrator.McpServer` lazy rebuild). So in production (live
  claude) every join was rejected `:orchestrator_not_registered` for the whole
  90s gate → timeout → full create rollback, blocking the orchestrator + admin
  UI on a fresh stack. The deterministic suite masked it (test-mode signals
  readiness without a live MCP join).

  The fix pre-persists the deterministic planned orchestrator URI BEFORE the
  gate (`Materializer.prestore_planned_orchestrator_uri/2`, step 4.5). This
  test asserts the binding becomes resolvable via the EXACT live-join path
  (`McpServer.from_orchestrator_uri/1`) after ONLY steps 2-4 + the pre-store —
  with NO `ensure_orchestrator` and NO step 6/7 run — i.e. exactly the durable
  state a live MCP join sees while the gate is still polling. Pre-fix the
  pre-store did not exist and the binding was absent, so this fails closed.
  """
  use ExUnit.Case, async: false

  alias Ezagent.Capability
  alias Ezagent.Entity.{Session, User}
  alias Ezagent.Orchestrator.{McpRegistry, McpServer}
  alias EzagentDomainInstanceMessage.SessionCreator.Materializer

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, {:shared, self()})

    # Admin User Kind alive — orchestrator-spawn / owner-lineage paths read it.
    _ = Ezagent.SpawnRegistry.spawn(User.admin_uri())
    :ok
  end

  # Spawn a real Session Kind + bind + materialize the orchestrator-backed
  # working copy (steps 2-4). NO orchestrator_uri is written yet — that is the
  # step-6 write the pre-store moves ahead of the gate.
  defp staged_session do
    owner = User.admin_uri()
    short = "prestore-#{System.unique_integer([:positive])}"
    session_uri = URI.new!("session://system/default/#{short}")
    workspace_uri = Capability.workspace_of(session_uri)
    session_template_uri = URI.new!("template://system/session/#{short}@abc123")
    orchestrator_template_uri = URI.new!("template://system/agent/cc-orchestrator")

    {:ok, _pid} =
      Ezagent.Kind.spawn(Session, %{
        uri: session_uri,
        owner_uri: owner,
        behaviors: Session.behaviors()
      })

    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, workspace_uri)

    :ok =
      Materializer.materialize_orchestrator_working_copy(
        session_uri,
        session_template_uri,
        orchestrator_template_uri
      )

    {session_uri, workspace_uri}
  end

  test "planned orchestrator binding is resolvable by the live-join path before ensure_orchestrator" do
    {session_uri, workspace_uri} = staged_session()
    planned = Session.planned_orchestrator_uri(session_uri, workspace_uri)
    :ok = McpRegistry.unregister(planned)

    # PRECONDITION (the bug): before the pre-store the live MCP join cannot
    # resolve the orchestrator from the durable snapshot — exactly what made
    # the readiness gate time out for the whole 90s window.
    assert McpServer.from_orchestrator_uri(planned) ==
             {:error, :orchestrator_not_registered}

    # THE FIX: step 4.5 pre-store of the deterministic planned binding.
    :ok = Materializer.prestore_planned_orchestrator_uri(session_uri, workspace_uri)
    # Clear the cache the precondition probe might have left, so the assertion
    # below proves a fresh durable rebuild (not a stale ETS row).
    :ok = McpRegistry.unregister(planned)

    # THE GATE: the live MCP-join path now resolves purely from the durable
    # session snapshot — no ensure_orchestrator, no step 6/7 have run.
    assert {:ok, :registered} = McpServer.from_orchestrator_uri(planned),
           "after the step-4.5 pre-store the durable session→orchestrator " <>
             "binding must be resolvable by the live MCP-join path while the " <>
             "readiness gate is still polling"
  end

  test "pre-store is clobber-safe: an already-present binding is preserved (repair/adopt path)" do
    {session_uri, workspace_uri} = staged_session()

    existing =
      URI.new!(
        "entity://system/agent/cc_orchestrator-adopted-#{System.unique_integer([:positive])}"
      )

    :ok = Materializer.store_session_orchestrator_uri(session_uri, existing)
    :ok = Materializer.prestore_planned_orchestrator_uri(session_uri, workspace_uri)

    wc = Session.read_template_working_copy(session_uri)

    assert URI.to_string(Map.get(wc, :orchestrator_uri)) == URI.to_string(existing),
           "pre-store must NOT clobber an already-present binding (repair/adopt path)"
  end
end
