defmodule EzagentDomainInstanceMessage.Integration.OrchestratorMcpReregisterTest do
  @moduledoc """
  Invariant test for Task #110 — the orchestrator MCP context must be
  recoverable after a PURE phx restart (durable Session snapshot present,
  the in-memory `McpRegistry` ETS table EMPTY, and NO lifecycle hook
  having re-registered the row), so the orchestrator's `orch:bridge:<uri>`
  channel join succeeds (and its 7 management MCP tools work) WITHOUT a
  fresh session re-spawn.

  ## The bug

  `Ezagent.Orchestrator.McpRegistry` is an in-memory ETS table
  (orchestrator URI → `(session_uri, workspace_uri, owner_uri,
  parent_template_uri)`). The Generator wrote the row ONLY at
  session-spawn time. On a phx restart the ETS table is empty and the
  Generator path never re-runs, so `McpServer.from_orchestrator_uri/1`
  fail-closed every bridge join with `{:error, :orchestrator_not_registered}`.

  ## The structural fix (lazy rebuild — read-through cache)

  `McpServer.from_orchestrator_uri/1` now treats `McpRegistry` as a
  CACHE. On an ETS miss it LAZILY REBUILDS the context from the Session's
  DURABLE `kind_snapshots` row (Session is `{:snapshot, :on_change}`) and
  fills the cache. No dependency on the ETS row surviving; no dependency
  on a lifecycle hook re-registering.

  ## The gate

  These tests simulate a PURE phx restart: persist a Session snapshot,
  delete the ETS row (NO register / no on_ready), then assert
  `from_orchestrator_uri/1` returns `{:ok, ctx}` with the full correct
  context. Per memory `feedback_completion_requires_invariant_test`, this
  is the gate that fails the moment lazy rebuild regresses.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Capability
  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.ActionSet.Session, as: SessionBehavior
  alias Ezagent.Entity.Session
  alias Ezagent.Orchestrator.{McpRegistry, McpServer}
  alias Ezagent.Test.SnapshotFixtures

  defp unique_session_uri do
    Ezagent.URI.session(
      "team-alpha",
      :default,
      "owner-mcp-reregister-#{System.unique_integer([:positive])}"
    )
  end

  # Build a Session :chat slice that carries an orchestrator-backed
  # template_working_copy — exactly the shape the Generator persists
  # (template-SHAPED working copy + the Task #110 :session_template_uri).
  defp orchestrator_chat_slice(opts) do
    wc = %{
      routing_rules: [],
      default_workspace_uri: Ezagent.URI.new!("workspace://default"),
      description: "task #110 fixture"
    }

    # Legacy snapshots (pre-#110) have NO :session_template_uri key.
    wc =
      case Keyword.fetch(opts, :session_template_uri) do
        {:ok, stu} -> Map.put(wc, :session_template_uri, stu)
        :error -> wc
      end

    %{
      members: %{},
      monitors: %{},
      last_seen: %{},
      owner_uri: Keyword.fetch!(opts, :owner_uri),
      template_working_copy: wc
    }
  end

  # Persist a Session snapshot AND clear the ETS row — the exact state a
  # phx process has right after a restart: durable snapshot on disk, ETS
  # cache empty, no register/on_ready having run.
  defp pure_restart_state(session_uri, chat_slice) do
    workspace_uri = Capability.workspace_of(session_uri)
    orchestrator_uri = Session.planned_orchestrator_uri(session_uri, workspace_uri)
    chat_slice = put_active_binding(chat_slice, orchestrator_uri)

    :ok = KindSnapshot.delete(URI.to_string(session_uri))
    :ok = McpRegistry.unregister(orchestrator_uri)
    :ok = SnapshotFixtures.save_kind_snapshot(session_uri, Session, %{session: chat_slice})

    # Assert the precondition that makes this a REAL restart simulation.
    assert McpRegistry.lookup(orchestrator_uri) == :error

    {workspace_uri, orchestrator_uri}
  end

  describe "lazy rebuild from durable snapshot — THE GATE (pure phx restart)" do
    test "a stale warm cache epoch is rejected and rebuilt from the current binding" do
      session_uri = unique_session_uri()
      owner_uri = Ezagent.URI.new!("entity://default/user/owner-stale-cache")
      session_template_uri = Ezagent.URI.new!("template://default/session/stale-cache@abc123")

      chat_slice =
        orchestrator_chat_slice(
          owner_uri: owner_uri,
          session_template_uri: session_template_uri
        )

      {workspace_uri, orchestrator_uri} = pure_restart_state(session_uri, chat_slice)

      :ok =
        McpRegistry.register(orchestrator_uri,
          session_uri: session_uri,
          workspace_uri: workspace_uri,
          owner_uri: owner_uri,
          parent_template_uri: session_template_uri,
          binding_epoch: "stale-warm-cache-epoch"
        )

      assert {:ok, :registered} = McpServer.from_orchestrator_uri(orchestrator_uri)
      assert {:ok, ctx} = McpRegistry.lookup(orchestrator_uri)
      refute ctx.binding_epoch == "stale-warm-cache-epoch"

      snapshot = KindSnapshot.get(URI.to_string(session_uri))
      {:ok, %{session: persisted_chat}} = KindSnapshot.decode_state(snapshot)
      persisted_chat = Ezagent.Kind.normalize_slice_view(persisted_chat)
      working_copy = Map.fetch!(persisted_chat, :template_working_copy)

      assert ctx.binding_epoch ==
               Map.fetch!(working_copy, :orchestrator_materialization_epoch)
    end

    test "a tombstoned binding is discoverable and fails loud" do
      session_uri = unique_session_uri()
      owner_uri = Ezagent.URI.new!("entity://default/user/owner-tombstone")

      orchestrator_uri =
        Ezagent.URI.entity(
          "team-alpha",
          :agent,
          "tombstoned-orchestrator-#{System.unique_integer([:positive])}"
        )

      working_copy = %{
        orchestrator_uri: %{
          uri: orchestrator_uri,
          epoch: "failed-epoch",
          status: :tombstone,
          reason: :synthetic_spawn_failure
        },
        orchestrator_materialization_epoch: "failed-epoch",
        session_template_uri: Ezagent.URI.new!("template://default/session/tombstone@abc123")
      }

      chat_slice = %{
        members: %{},
        monitors: %{},
        last_seen: %{},
        owner_uri: owner_uri,
        template_working_copy: working_copy
      }

      :ok = KindSnapshot.delete(URI.to_string(session_uri))
      :ok = McpRegistry.unregister(orchestrator_uri)

      :ok =
        SnapshotFixtures.save_kind_snapshot(session_uri, Session, %{session: %{state: chat_slice}})

      assert McpServer.from_orchestrator_uri(orchestrator_uri) ==
               {:error, {:orchestrator_binding_tombstoned, :synthetic_spawn_failure}}

      assert McpRegistry.lookup(orchestrator_uri) == :error
    end

    test "rebuilds an ordinary role/member orchestrator without legacy OTU" do
      session_uri = unique_session_uri()
      workspace_uri = Capability.workspace_of(session_uri)
      owner_uri = Ezagent.URI.new!("entity://default/user/owner-role-member")
      session_template_uri = Ezagent.URI.new!("template://default/session/role-member@abc123")

      orchestrator_uri =
        Ezagent.URI.entity(
          "team-alpha",
          :agent,
          "ordinary-orchestrator-#{System.unique_integer([:positive])}"
        )

      working_copy = %{
        orchestrator_uri: active_binding(orchestrator_uri, "ordinary-epoch"),
        orchestrator_materialization_epoch: "ordinary-epoch",
        session_template_uri: session_template_uri,
        routing_rules: []
      }

      refute Map.has_key?(working_copy, :orchestrator_template_uri)

      chat_slice = %{
        members: %{
          orchestrator_uri => %{
            online: true,
            role_name: "orchestrator"
          }
        },
        monitors: %{},
        last_seen: %{},
        owner_uri: owner_uri,
        template_working_copy: working_copy
      }

      :ok = KindSnapshot.delete(URI.to_string(session_uri))
      :ok = McpRegistry.unregister(orchestrator_uri)

      :ok =
        SnapshotFixtures.save_kind_snapshot(session_uri, Session, %{
          session: %{state: chat_slice}
        })

      assert McpRegistry.lookup(orchestrator_uri) == :error
      assert {:ok, :registered} = McpServer.from_orchestrator_uri(orchestrator_uri)

      assert {:ok, ctx} = McpRegistry.lookup(orchestrator_uri)
      assert ctx.session_uri == session_uri
      assert ctx.workspace_uri == workspace_uri
      assert ctx.owner_uri == owner_uri
      assert ctx.parent_template_uri == session_template_uri
    end

    test "from_orchestrator_uri rebuilds the full context on an ETS miss" do
      session_uri = unique_session_uri()
      owner_uri = Ezagent.URI.new!("entity://default/user/owner-mcp")
      session_template_uri = Ezagent.URI.new!("template://default/session/owner-mcp-team@abc123")

      chat_slice =
        orchestrator_chat_slice(
          owner_uri: owner_uri,
          session_template_uri: session_template_uri
        )

      {workspace_uri, orchestrator_uri} = pure_restart_state(session_uri, chat_slice)

      # The fix: with the ETS row gone, from_orchestrator_uri rebuilds it
      # from the durable snapshot. Pre-fix this returned
      # {:error, :orchestrator_not_registered}.
      assert {:ok, :registered} = McpServer.from_orchestrator_uri(orchestrator_uri),
             "from_orchestrator_uri must LAZILY REBUILD the context from the " <>
               "durable Session snapshot on an ETS miss (pure phx restart) — " <>
               "Task #110 read-through cache"

      # Transport #53 Decision C: the cc transport no longer carries the
      # session/owner/parent context — the SessionManager (session domain)
      # reconstructs it. `from_orchestrator_uri/1` is now the readiness gate;
      # its rebuild side-effect fills the McpRegistry row, asserted below.

      # Cache was filled as a side-effect of the rebuild — the registry row
      # still records the FULL context (the readiness/register API is
      # unchanged) the session action reads/reconstructs from.
      assert {:ok, ctx} = McpRegistry.lookup(orchestrator_uri)
      assert URI.to_string(ctx.session_uri) == URI.to_string(session_uri)
      assert URI.to_string(ctx.workspace_uri) == URI.to_string(workspace_uri)
      assert URI.to_string(ctx.owner_uri) == URI.to_string(owner_uri)

      assert URI.to_string(ctx.parent_template_uri) == URI.to_string(session_template_uri),
             "parent_template_uri must be recovered from the durable " <>
               "template_working_copy.session_template_uri so update_template works"
    end

    test "rebuilds from the PERSISTED TWO-CONTAINER chat slice (transients stripped) — the real regression" do
      # The sibling test above persists a FLAT chat slice. But a converted
      # Behavior.Session (use Ezagent.Lifecycle) persists the TWO-CONTAINER
      # shape, and the snapshot path strips :transients, so the ON-DISK
      # :chat value is a single-key %{state: persistent}. This is the shape
      # production actually writes — and the regression (normalize_slice_view
      # only unwrapping %{state, transients}, never the persisted single-key
      # %{state}) made from_orchestrator_uri fail-closed for EVERY real
      # orchestrator session after a restart. Without the single-key clause
      # in Ezagent.Kind.normalize_slice_view/1 this assertion fails with
      # {:error, :orchestrator_not_registered}.
      session_uri = unique_session_uri()
      owner_uri = Ezagent.URI.new!("entity://default/user/owner-2c")
      session_template_uri = Ezagent.URI.new!("template://default/session/owner-2c-team@def456")

      chat_slice =
        orchestrator_chat_slice(owner_uri: owner_uri, session_template_uri: session_template_uri)

      workspace_uri = Capability.workspace_of(session_uri)
      orchestrator_uri = Session.planned_orchestrator_uri(session_uri, workspace_uri)

      chat_slice = put_active_binding(chat_slice, orchestrator_uri)

      :ok = KindSnapshot.delete(URI.to_string(session_uri))
      :ok = McpRegistry.unregister(orchestrator_uri)
      # Persist the EXACT on-disk shape: :chat wrapped in single-key %{state}
      # (what strip_transients leaves of the two-container in-memory slice).
      :ok =
        SnapshotFixtures.save_kind_snapshot(session_uri, Session, %{session: %{state: chat_slice}})

      assert McpRegistry.lookup(orchestrator_uri) == :error

      assert {:ok, :registered} = McpServer.from_orchestrator_uri(orchestrator_uri),
             "from_orchestrator_uri must rebuild from the PERSISTED two-container " <>
               "(single-key %{state}) chat slice — the production shape"

      # The rebuild side-effect filled the cache row; session/owner/parent
      # recovery is verified on it (the SessionManager reconstructs from it /
      # the durable working copy).
      assert {:ok, ctx} = McpRegistry.lookup(orchestrator_uri)
      assert URI.to_string(ctx.session_uri) == URI.to_string(session_uri)
      assert URI.to_string(ctx.owner_uri) == URI.to_string(owner_uri)
      assert URI.to_string(ctx.parent_template_uri) == URI.to_string(session_template_uri)
    end

    test "concurrent rebuilds are idempotent — same single cache row, no crash" do
      session_uri = unique_session_uri()
      owner_uri = Ezagent.URI.new!("entity://default/user/owner-idem")
      session_template_uri = Ezagent.URI.new!("template://default/session/owner-idem-team@def456")

      chat_slice =
        orchestrator_chat_slice(
          owner_uri: owner_uri,
          session_template_uri: session_template_uri
        )

      {_workspace_uri, orchestrator_uri} = pure_restart_state(session_uri, chat_slice)

      # Simulate the bridge join storm: N joins racing the same lazy
      # rebuild. ETS :set put is atomic + the rebuilt context is a pure
      # function of the durable snapshot, so every racer writes an
      # identical row — no torn state, no crash.
      results =
        1..16
        |> Task.async_stream(fn _ -> McpServer.from_orchestrator_uri(orchestrator_uri) end,
          max_concurrency: 16,
          ordered: false
        )
        |> Enum.map(fn {:ok, r} -> r end)

      assert Enum.all?(results, &match?({:ok, :registered}, &1))

      # Exactly one row, with the correct context.
      assert {:ok, ctx} = McpRegistry.lookup(orchestrator_uri)
      assert URI.to_string(ctx.session_uri) == URI.to_string(session_uri)
      assert URI.to_string(ctx.parent_template_uri) == URI.to_string(session_template_uri)

      rows = :ets.lookup(McpRegistry.table(), URI.to_string(orchestrator_uri))
      assert length(rows) == 1, "concurrent rebuild must leave exactly one ETS row"
    end
  end

  describe "legacy snapshot (no :session_template_uri) — MED finding" do
    test "rebuild succeeds; parent_template_uri is nil and update_template errors cleanly" do
      session_uri = unique_session_uri()
      owner_uri = Ezagent.URI.new!("entity://default/user/owner-legacy")

      # Pre-#110 working copy: orchestrator-backed but NO session_template_uri.
      chat_slice = orchestrator_chat_slice(owner_uri: owner_uri)

      {workspace_uri, orchestrator_uri} = pure_restart_state(session_uri, chat_slice)

      # Rebuild still succeeds (the session HAS an orchestrator) — the 6
      # tools that do not need parent_template_uri work after restart.
      assert {:ok, :registered} = McpServer.from_orchestrator_uri(orchestrator_uri)

      # Decision C: parent recovery is now a SESSION-side concern; the
      # transport's cache row carries the recovered (here: unrecoverable →
      # nil) parent_template_uri. A legacy snapshot's parent is structurally
      # unrecoverable (content-addressed hash is not in any durable legacy
      # field) — it MUST be nil, never a guessed default. The session action
      # then surfaces the loud `:missing_context` for update_template (the
      # op-level error mapping is covered by the session-domain ops test).
      assert {:ok, ctx} = McpRegistry.lookup(orchestrator_uri)
      assert URI.to_string(ctx.workspace_uri) == URI.to_string(workspace_uri)

      assert ctx.parent_template_uri == nil,
             "a legacy snapshot's parent_template_uri is structurally " <>
               "unrecoverable (content-addressed hash is not in any durable " <>
               "legacy field) — it MUST be nil, never a guessed default"
    end
  end

  describe "no-orchestrator session — legitimate fail-closed" do
    test "a plain session (no orchestrator binding) returns :orchestrator_not_registered" do
      session_uri = unique_session_uri()
      workspace_uri = Capability.workspace_of(session_uri)
      orchestrator_uri = Session.planned_orchestrator_uri(session_uri, workspace_uri)

      :ok = KindSnapshot.delete(URI.to_string(session_uri))
      :ok = McpRegistry.unregister(orchestrator_uri)

      # A fresh / system session has no orchestrator binding.
      plain_slice = %{
        members: %{},
        monitors: %{},
        last_seen: %{},
        owner_uri: nil,
        template_working_copy: SessionBehavior.default_template_working_copy()
      }

      :ok = SnapshotFixtures.save_kind_snapshot(session_uri, Session, %{session: plain_slice})

      assert McpServer.from_orchestrator_uri(orchestrator_uri) ==
               {:error, :orchestrator_not_registered},
             "a session with no orchestrator is a legitimate fail-closed — " <>
               "lazy rebuild must NOT fabricate a context for it"

      # Nothing was cached.
      assert McpRegistry.lookup(orchestrator_uri) == :error
    end

    test "a never-existed orchestrator URI (no session snapshot at all) fails closed" do
      orchestrator_uri =
        URI.parse(
          "entity://team-alpha/agent/cc_orchestrator-ghost-#{System.unique_integer([:positive])}"
        )

      :ok = McpRegistry.unregister(orchestrator_uri)

      assert McpServer.from_orchestrator_uri(orchestrator_uri) ==
               {:error, :orchestrator_not_registered}

      assert McpRegistry.lookup(orchestrator_uri) == :error
    end
  end

  defp put_active_binding(chat_slice, orchestrator_uri) do
    epoch = "fixture-#{System.unique_integer([:positive])}"

    chat_slice
    |> put_in(
      [:template_working_copy, :orchestrator_uri],
      active_binding(orchestrator_uri, epoch)
    )
    |> put_in([:template_working_copy, :orchestrator_materialization_epoch], epoch)
  end

  defp active_binding(uri, epoch) do
    %{uri: uri, epoch: epoch, status: :active, reason: nil}
  end
end
