defmodule Ezagent.Orchestrator.HealthTest do
  @moduledoc """
  Unit + light-integration tests for `Ezagent.Orchestrator.Health` —
  the per-session orchestrator-instance status classifier surfaced on
  the `/sessions` UI health card.

  Three states gated:

    * `:not_spawned` — neither live process nor snapshot row
    * `:alive` — live process registered at the orchestrator URI
    * `:crashed` — snapshot row exists but no live process

  Plus the structural guard: an unbound session URI returns
  `{:error, :session_not_workspace_bound}` (no silent default
  workspace per `feedback_let_it_crash_no_workarounds`).
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.KindRegistry
  alias Ezagent.Orchestrator.Health
  alias Ezagent.Test.SnapshotFixtures
  alias Ezagent.WorkspaceRegistry

  setup do
    session_uri =
      URI.new!("session://system/default/orchhealth-#{System.unique_integer([:positive])}")

    workspace_uri = URI.new!("workspace://system")

    # Health classifier asks WorkspaceRegistry — bind in setup so the
    # happy paths return `{:ok, health}`; the unbound case has a
    # dedicated test that skips this binding.
    :ok = WorkspaceRegistry.bind(session_uri, workspace_uri)

    on_exit(fn ->
      WorkspaceRegistry.unbind(session_uri)
    end)

    {:ok, session_uri: session_uri, workspace_uri: workspace_uri}
  end

  describe "classify/1" do
    test ":not_spawned when neither live process nor snapshot exists", %{
      session_uri: session_uri,
      workspace_uri: workspace_uri
    } do
      assert {:ok, health} = Health.classify(session_uri)

      expected_uri =
        URI.new!(
          "entity://system/agent/cc_orchestrator-" <>
            session_discriminator(session_uri)
        )

      assert URI.to_string(health.uri) == URI.to_string(expected_uri)
      assert health.status == :not_spawned
      refute Map.has_key?(health, :pid)
      assert health.snapshot_updated_at == nil
      assert URI.to_string(health.workspace_uri) == URI.to_string(workspace_uri)
      assert health.instance_name == "cc_orchestrator-" <> session_discriminator(session_uri)

      assert URI.to_string(health.template_uri) ==
               "template://system/agent/cc-orchestrator"
    end

    test ":alive when a live pid is registered at the orchestrator URI", %{
      session_uri: session_uri
    } do
      orch_uri =
        Ezagent.Entity.Session.planned_orchestrator_uri(
          session_uri,
          URI.new!("workspace://system")
        )

      # Spawn a stand-in process; register it under the orchestrator
      # URI. Real orchestrators register via `Kind.Server.init/1` →
      # `KindRegistry.put_new/2`; for the classifier unit test we only
      # need a live pid at the right key.
      test_pid = self()

      child_pid =
        spawn(fn ->
          KindRegistry.put_new(orch_uri, self())
          send(test_pid, :registered)

          receive do
            :stop -> :ok
          end
        end)

      assert_receive :registered, 500

      try do
        assert {:ok, health} = Health.classify(session_uri)
        assert health.status == :alive
        refute Map.has_key?(health, :pid)
      after
        send(child_pid, :stop)
      end
    end

    test ":crashed when a snapshot row exists but no live process", %{
      session_uri: session_uri,
      workspace_uri: workspace_uri
    } do
      orch_uri =
        Ezagent.Entity.Session.planned_orchestrator_uri(session_uri, workspace_uri)

      # Insert a snapshot row to model "orchestrator was spawned and
      # has since died"; use the test fixture helper so low-level
      # snapshot writes stay centralized.
      {:ok, _row} =
        SnapshotFixtures.upsert_kind_snapshot(
          URI.to_string(orch_uri),
          "Elixir.Ezagent.Entity.Agent",
          :erlang.term_to_binary(%{}),
          0,
          URI.to_string(workspace_uri)
        )

      # No process registered under the URI → KindRegistry.lookup
      # returns :error → snapshot present → :crashed.
      assert {:ok, health} = Health.classify(session_uri)
      assert health.status == :crashed
      refute Map.has_key?(health, :pid)
      assert %DateTime{} = health.snapshot_updated_at

      # Cleanup so the snapshot doesn't leak into other tests sharing
      # this Repo connection (`async: false` plus DataCase sandbox
      # already isolates, but we're explicit).
      KindSnapshot.delete(URI.to_string(orch_uri))
    end

    test "returns {:error, :session_not_workspace_bound} when session has no binding" do
      unbound =
        URI.new!("session://system/default/unbound-#{System.unique_integer([:positive])}")

      # Do NOT bind via WorkspaceRegistry.

      assert {:error, :session_not_workspace_bound} = Health.classify(unbound)
    end
  end

  describe "classify_in_workspace/2" do
    test "bypasses WorkspaceRegistry — works when caller supplies workspace", %{
      session_uri: session_uri,
      workspace_uri: workspace_uri
    } do
      health = Health.classify_in_workspace(session_uri, workspace_uri)
      assert health.status == :not_spawned
      assert URI.to_string(health.workspace_uri) == URI.to_string(workspace_uri)
    end

    test "raises ArgumentError for workspace URI with no host" do
      session_uri = URI.new!("session://system/default/x")
      bad_workspace = %URI{scheme: "workspace", host: nil}

      assert_raise ArgumentError, ~r/URI has no workspace scope/, fn ->
        Health.classify_in_workspace(session_uri, bad_workspace)
      end
    end
  end

  # The Session module's session_discriminator is private; reconstruct
  # the same logic here for assertions. The discriminator IS the
  # session URI's name segment unchanged (e.g. session://system/default/orchhealth-7
  # → "orchhealth-7").
  defp session_discriminator(%URI{path: "/" <> rest} = uri) do
    case String.split(rest, "/", parts: 2) do
      [_ws, name] when name != "" -> name
      _ -> uri.host || "session"
    end
  end
end
