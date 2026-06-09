defmodule EzagentPluginLiveview.AdminLiveOrchestratorHealthTest do
  @moduledoc """
  Per-session orchestrator-instance health card LV tests (2026-05-26).

  Asserts the three classification states render correctly + the
  Restart button visibility gate:

    * `:not_spawned` → gray "not spawned" badge, URI as plain mono text,
      NO Restart button.
    * `:alive` → green "alive" badge, URI as a link to the agent detail
      page, NO Restart button (nothing to restart).
    * `:crashed` → red "crashed" badge, URI as a link, Restart button
      visible (and only when caller holds the cap).
  """

  use ExUnit.Case
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.KindRegistry
  alias Ezagent.Test.SnapshotFixtures

  @endpoint EzagentWeb.Endpoint
  @main_session_uri Ezagent.URI.new!("session://system/default/main")
  @main_workspace_uri Ezagent.URI.new!("workspace://system")

  defp create_session_via_workspace(short_name, creator_uri, opts) do
    template_name = Keyword.fetch!(opts, :template_name)

    workspace_uri =
      Keyword.get(opts, :workspace_uri, Ezagent.Capability.workspace_of(creator_uri))

    ensure_workspace_seeded!(workspace_uri)

    with {:ok, result} <-
           Ezagent.Workspace.create_session(
             workspace_uri,
             %{short_name: short_name, template_name: template_name},
             %{caller: creator_uri, caps: Ezagent.SystemPrincipal.caps("system://bootstrap")}
           ) do
      {:ok, result.session_uri,
       %{
         orchestrator_uri: result.orchestrator_uri,
         orchestrator_status: result.orchestrator_status,
         orchestrator_error: result.orchestrator_error
       }}
    end
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, {:shared, self()})

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{
        "current_entity_uri" => URI.to_string(Ezagent.Entity.User.admin_uri())
      })

    # The boot path binds session://system/default/main to workspace://system; the
    # orchestrator URI derives from that pair. Sanity-check the binding
    # so any boot-order regression surfaces here rather than as a
    # confusing :session_not_workspace_bound failure deeper down.
    case Ezagent.WorkspaceRegistry.lookup(@main_session_uri) do
      {:ok, _} -> :ok
      :error -> :ok = Ezagent.WorkspaceRegistry.bind(@main_session_uri, @main_workspace_uri)
    end

    # Pre-create the main session so AdminLive.ensure_main_session is a
    # no-op at mount. The mount otherwise lazily creates the session via
    # `create_session/3`, which AUTO-SPAWNS a live cc-orchestrator —
    # resurrecting the very orchestrator each `:not_spawned` / `:crashed`
    # test tore down, so `classify/1` always reported `:alive`. With the
    # session already live, the mount skips creation and each test's
    # `ensure_no_orchestrator/1` (which now properly terminates the
    # orchestrator Kind, not just kills the supervised pid) survives.
    # (post-lifecycle remediation.)
    case Ezagent.KindRegistry.lookup(@main_session_uri) do
      {:ok, _pid} ->
        :ok

      :error ->
        {:ok, _spawned, _meta} =
          create_session_via_workspace("main", Ezagent.Entity.User.admin_uri(),
            template_name: "default",
            workspace_uri: @main_workspace_uri
          )

        :ok
    end

    orch_uri =
      Ezagent.Entity.Session.planned_orchestrator_uri(
        @main_session_uri,
        @main_workspace_uri
      )

    {:ok, conn: conn, orch_uri: orch_uri}
  end

  describe "orchestrator health card — three states" do
    test ":not_spawned renders gray badge + URI as plain mono text, no Restart", %{
      conn: conn,
      orch_uri: orch_uri
    } do
      # No registration, no snapshot row → not_spawned.
      :ok = ensure_no_orchestrator(orch_uri)

      {:ok, _lv, html} = live(conn, "/sessions")

      assert html =~ ~s(id="orchestrator-health-card")
      assert html =~ "not spawned"
      assert html =~ ~s(id="orchestrator-health-uri-text")
      assert html =~ URI.to_string(orch_uri)

      # No link wrapper in not_spawned state.
      refute html =~ ~s(id="orchestrator-health-uri-link")
      # No restart button.
      refute html =~ ~s(id="restart-orchestrator-button")
    end

    test ":alive renders green badge + URI as link, no Restart button", %{
      conn: conn,
      orch_uri: orch_uri
    } do
      :ok = ensure_no_orchestrator(orch_uri)

      # Spawn a stand-in process registered under the orchestrator URI
      # so KindRegistry.lookup returns {:ok, pid} and Process.alive?
      # is true.
      test_pid = self()

      child =
        spawn(fn ->
          KindRegistry.put_new(orch_uri, self())
          send(test_pid, :registered)

          receive do
            :stop -> :ok
          end
        end)

      assert_receive :registered, 500

      try do
        {:ok, _lv, html} = live(conn, "/sessions")

        assert html =~ ~s(id="orchestrator-health-card")
        assert html =~ "alive"
        assert html =~ ~s(id="orchestrator-health-uri-link")
        assert html =~ URI.to_string(orch_uri)

        refute html =~ ~s(id="restart-orchestrator-button")
      after
        send(child, :stop)
      end
    end

    test ":crashed renders red badge + URI as link + Restart button (admin caps)", %{
      conn: conn,
      orch_uri: orch_uri
    } do
      :ok = ensure_no_orchestrator(orch_uri)

      # Persist a kind_snapshots row to model "spawned but no longer
      # alive"; use the test fixture helper so low-level snapshot
      # writes stay centralized.
      {:ok, _row} =
        SnapshotFixtures.upsert_kind_snapshot(
          URI.to_string(orch_uri),
          "Elixir.Ezagent.Entity.Agent",
          :erlang.term_to_binary(%{}),
          0,
          URI.to_string(@main_workspace_uri)
        )

      try do
        {:ok, _lv, html} = live(conn, "/sessions")

        assert html =~ ~s(id="orchestrator-health-card")
        assert html =~ "crashed"
        assert html =~ ~s(id="orchestrator-health-uri-link")
        assert html =~ URI.to_string(orch_uri)

        # Admin caller has the `:any` baseline cap → can_restart? = true →
        # button visible.
        assert html =~ ~s(id="restart-orchestrator-button")
        assert html =~ "Restart orchestrator"
      after
        KindSnapshot.delete(URI.to_string(orch_uri))
      end
    end

    test "RFC #402 — non-owner sees crashed status but NO Restart button", %{
      orch_uri: orch_uri
    } do
      # Build a conn for a NON-admin user (no OrchestratorAdmin cap,
      # no all-caps admin grant). `caller_can_restart_orchestrator?/2`
      # consults `caller_caps` directly, so the simplest way to
      # exercise the gate is to mount as a fresh entity with no caps.
      non_owner_uri =
        URI.new!("entity://system/user/non-owner-#{System.unique_integer([:positive])}")

      # Spawn the User Kind so AdminLive's `assign_session_context`
      # can resolve `caller_caps` from its Identity slice. Without a
      # live Kind, the LV may fall back to admin caps in test env —
      # we want the explicit "no-cap" pathway exercised.
      _ = Ezagent.SpawnRegistry.spawn(non_owner_uri)

      non_owner_conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Test.init_test_session(%{
          "current_entity_uri" => URI.to_string(non_owner_uri)
        })

      :ok = ensure_no_orchestrator(orch_uri)

      {:ok, _row} =
        SnapshotFixtures.upsert_kind_snapshot(
          URI.to_string(orch_uri),
          "Elixir.Ezagent.Entity.Agent",
          :erlang.term_to_binary(%{}),
          0,
          URI.to_string(@main_workspace_uri)
        )

      try do
        case live(non_owner_conn, "/sessions") do
          {:ok, _lv, html} ->
            # The non-owner can SEE the orchestrator status (visibility
            # is read-only) but CANNOT see the Restart button (RFC #402
            # — restart authority is session-owner-bound).
            assert html =~ ~s(id="orchestrator-health-card")
            assert html =~ "crashed"

            refute html =~ ~s(id="restart-orchestrator-button"),
                   "RFC #402: non-owner must not see the Restart button"

          {:error, {:redirect, _}} ->
            # Some auth paths in the LV redirect non-admin users away
            # from /sessions; that's a stricter form of the same gate
            # (RFC #402 holds — they certainly can't restart from a
            # page they can't reach).
            :ok
        end
      after
        KindSnapshot.delete(URI.to_string(orch_uri))
      end
    end
  end

  defp ensure_workspace_seeded!(workspace_uri, retries \\ 5)

  defp ensure_workspace_seeded!(%URI{scheme: "workspace", host: name} = workspace_uri, retries)
       when is_binary(name) and name != "" do
    case Ezagent.Workspace.Store.get_by_name(name) do
      nil ->
        try do
          case Ezagent.Workspace.create(name, %{}) do
            {:ok, _pid} -> :ok
            {:error, :workspace_exists} -> :ok
            {:error, {:already_started, _pid}} -> :ok
            {:error, reason} -> raise "failed to seed workspace #{name}: #{inspect(reason)}"
          end
        rescue
          error ->
            if retries > 0 do
              Process.sleep(50)
              ensure_workspace_seeded!(workspace_uri, retries - 1)
            else
              reraise error, __STACKTRACE__
            end
        end

      _ ->
        :ok
    end
  end

  # Tear down any prior orchestrator state from another test in the
  # same Repo connection — Registry.unregister via the owner process,
  # plus snapshot row delete. Used as a defensive prelude to each
  # describe-block test (the boot path doesn't spawn an orchestrator
  # for session://system/default/main in test env, but other tests in this file may
  # have).
  defp ensure_no_orchestrator(%URI{} = orch_uri) do
    # Snapshot rows leak across tests sharing the sandbox connection;
    # always start clean.
    KindSnapshot.delete(URI.to_string(orch_uri))

    # If a previous test (or the session's auto-spawn) left an
    # orchestrator registered, terminate the Kind PROPERLY via
    # `Ezagent.Kind.terminate/1` (DynamicSupervisor.terminate_child) so
    # it does NOT respawn — a bare `Process.exit(pid, :kill)` only trips
    # the supervisor, which immediately restarts the orchestrator and the
    # test keeps observing `:alive`. (post-lifecycle remediation.)
    case KindRegistry.lookup(orch_uri) do
      {:ok, pid} when is_pid(pid) ->
        ref = Process.monitor(pid)
        _ = Ezagent.Kind.terminate(orch_uri)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          500 -> :ok
        end

      :error ->
        :ok
    end

    # Registry's dead-pid cleanup is async — give it a beat so the
    # next lookup observes :error.
    Process.sleep(20)
    :ok
  end
end
