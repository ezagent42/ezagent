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

  @endpoint EzagentWeb.Endpoint
  @main_session_uri URI.new!("session://default/system/main")
  @main_workspace_uri URI.new!("workspace://system")

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, {:shared, self()})

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{
        "current_entity_uri" => URI.to_string(Ezagent.Entity.User.admin_uri())
      })

    # The boot path binds session://default/system/main to workspace://system; the
    # orchestrator URI derives from that pair. Sanity-check the binding
    # so any boot-order regression surfaces here rather than as a
    # confusing :session_not_workspace_bound failure deeper down.
    case Ezagent.WorkspaceRegistry.lookup(@main_session_uri) do
      {:ok, _} -> :ok
      :error -> :ok = Ezagent.WorkspaceRegistry.bind(@main_session_uri, @main_workspace_uri)
    end

    orch_uri =
      Ezagent.Entity.Session.derive_orchestrator_uri(
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
      # alive" — exact production write path so the row carries the
      # NOT-NULL workspace_uri column.
      {:ok, _row} =
        KindSnapshot.upsert(
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
      non_owner_uri = URI.new!("entity://user/system/non-owner-#{System.unique_integer([:positive])}")

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
        KindSnapshot.upsert(
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

  # Tear down any prior orchestrator state from another test in the
  # same Repo connection — Registry.unregister via the owner process,
  # plus snapshot row delete. Used as a defensive prelude to each
  # describe-block test (the boot path doesn't spawn an orchestrator
  # for session://default/system/main in test env, but other tests in this file may
  # have).
  defp ensure_no_orchestrator(%URI{} = orch_uri) do
    # Snapshot rows leak across tests sharing the sandbox connection;
    # always start clean.
    KindSnapshot.delete(URI.to_string(orch_uri))

    # If a previous test left a pid registered, kill it so this test
    # observes :not_spawned (or its own setup).
    case KindRegistry.lookup(orch_uri) do
      {:ok, pid} when is_pid(pid) ->
        if Process.alive?(pid) do
          ref = Process.monitor(pid)
          Process.exit(pid, :kill)

          receive do
            {:DOWN, ^ref, :process, ^pid, _} -> :ok
          after
            500 -> :ok
          end
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
