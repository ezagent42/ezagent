defmodule Ezagent.Integration.SnapshotRestartTest do
  @moduledoc """
  Phase 4-completion Spec 04 invariant test (the architectural gate).

  Per memory `feedback_completion_requires_invariant_test`:
  Decision #27 promises 4 snapshot strategies actually work. This test
  proves **`{:snapshot, :on_change}` survives a Kind process restart**
  — the user-facing acceptance bar: "granting a cap to a User persists
  across restarts."

  Plus parametric coverage for `:on_terminate` and `:ephemeral` (no
  persistence). `:periodic` is exercised via direct Snapshot.save_now
  in snapshot_test.exs.
  """

  use EzagentCore.DataCase, async: false

  # #52 Mode-A: cross-tier suite — references sibling-app modules; resolves
  # only in the umbrella. Excluded standalone (`cd apps/ezagent_core && mix test`).
  @moduletag :umbrella_only

  alias Ezagent.{Invocation, KindRegistry}
  alias Ezagent.Ecto.KindSnapshot

  describe "{:snapshot, :on_change} restart roundtrip — THE GATE" do
    test "User caps granted before restart are present after restart" do
      uri =
        Ezagent.URI.new!(
          "entity://team-alpha/user/snap-restart-#{System.unique_integer([:positive])}"
        )

      {:ok, _user} = Ezagent.Users.create(uri, nil, [])

      # 1. Spawn a fresh User Kind. Born-signed storage starts empty.
      {:ok, pid1} =
        DynamicSupervisor.start_child(
          Ezagent.Workspace.Supervisor,
          {Ezagent.Kind.Server, {Ezagent.Entity.User, %{uri: uri, initial_caps: MapSet.new()}}}
        )

      wait_until(fn -> Ezagent.ReadyGate.status(uri) == :ready end)

      # 2. Grant through K.grant so the target authority signs the stored
      #    artifact and the real on-change path persists it.
      requested =
        Ezagent.Capability.cap(
          :user,
          Ezagent.ActionSet.Identity,
          :list_caps,
          uri,
          Ezagent.Capability.workspace_of(uri)
        )

      assert {:ok, _anchor} = Ezagent.Cap.Authority.anchor(uri)

      assert :ok =
               Ezagent.Identity.Grant.grant_cap(
                 uri,
                 requested,
                 {:admin, Ezagent.Entity.User.admin_uri()}
               )

      # 3. Verify DB row exists
      uri_str = URI.to_string(uri)
      assert %KindSnapshot{kind_type: "user"} = KindSnapshot.get(uri_str)

      # 4. Kill the Kind (via supervisor terminate, no auto-restart)
      :ok = DynamicSupervisor.terminate_child(Ezagent.Workspace.Supervisor, pid1)
      wait_until(fn -> KindRegistry.lookup(uri) == :error end)

      # 5. Restart Kind — init_slice with default empty caps
      {:ok, pid2} =
        DynamicSupervisor.start_child(
          Ezagent.Workspace.Supervisor,
          {Ezagent.Kind.Server, {Ezagent.Entity.User, %{uri: uri}}}
        )

      refute pid1 == pid2

      # 5b. Wait for the rehydrated User Kind to finish post_init
      # reconciliation (wildcard-cap-fix 2026-05-26 —
      # `Ezagent.ActionSet.Identity.post_init/2` queues a
      # caps_json-merge continuation for every user URI, and
      # `Ezagent.Kind.Server` keeps the Kind `:not_ready` through
      # post-init). Without this wait the synchronous `:call` dispatch
      # below races the continuation and fails fast with
      # `{:error, :not_ready}` per hard-invariant #3.
      #
      # For the test fixture URI (`entity://team-alpha/user/snap-restart-N`)
      # the `users` table has no row, so `handle_continue/3` returns
      # `:ignore` and the Kind reaches `:ready` after one continue
      # round — typically <1ms wall-clock.
      wait_until(fn -> Ezagent.ReadyGate.status(uri) == :ready end)

      # 6. Dispatch list_caps — should return the SAVED caps (admin_caps),
      #    not the fresh init's empty MapSet
      target = URI.new!("#{uri_str}?action=identity.list_caps")
      presenter = Ezagent.Entity.User.admin_uri()
      parent_cap = signed_action_cap!(target, presenter)

      assert {:ok, %{caps: cap_list}} =
               Invocation.dispatch(%Invocation{
                 origin: :trusted_internal,
                 target: target,
                 mode: :call,
                 args: %{},
                 ctx: %{
                   caller: presenter,
                   authenticated_principal: presenter,
                   caps: MapSet.new([parent_cap]),
                   reply: {:caller_inbox, self()}
                 }
               })

      assert Enum.count(
               cap_list,
               &(Ezagent.Capability.action_of(&1) == :self_license)
             ) == 1

      assert Enum.count(
               cap_list,
               &(Ezagent.Capability.action_of(&1) == :list_caps)
             ) == 1
    end
  end

  describe ":ephemeral does NOT persist" do
    test "TestKind state lost on restart" do
      uri = URI.new!("test://snap-eph-#{System.unique_integer([:positive])}")

      {:ok, pid1} =
        DynamicSupervisor.start_child(
          Ezagent.Workspace.Supervisor,
          {Ezagent.Kind.Server, {Ezagent.Test.TestKind, %{uri: uri}}}
        )

      # No KindSnapshot row should ever be written for :ephemeral
      :ok = DynamicSupervisor.terminate_child(Ezagent.Workspace.Supervisor, pid1)
      wait_until(fn -> KindRegistry.lookup(uri) == :error end)

      assert nil == KindSnapshot.get(URI.to_string(uri))
    end
  end

  describe "Agent (:on_change) writes at init and survives shutdown" do
    test "Agent init writes row immediately; graceful kill keeps it" do
      # Allen 2026-05-25 — CLI persistence fix: `Ezagent.Entity.Agent`
      # bumped from `:on_terminate` to `{:snapshot, :on_change}` so
      # post-spawn cap grants (`grant_initial_caps` dispatch) land
      # durably before mix BEAM exit. This test validates the
      # combined behaviour: init writes the row, and a subsequent
      # graceful terminate leaves it intact (no regression in the
      # restart roundtrip).
      uri =
        Ezagent.URI.new!(
          "entity://team-alpha/agent/test_snap-term-#{System.unique_integer([:positive])}"
        )

      {:ok, pid} =
        DynamicSupervisor.start_child(
          EzagentDomainInstanceMessage.AgentSupervisor,
          {Ezagent.Kind.Server, {Ezagent.Entity.Agent, %{uri: uri, initial_caps: MapSet.new()}}}
        )

      uri_str = URI.to_string(uri)

      # Row exists immediately after init (CLI persistence fix).
      assert %KindSnapshot{kind_type: "agent"} = KindSnapshot.get(uri_str)

      # Graceful terminate via supervisor
      :ok = DynamicSupervisor.terminate_child(EzagentDomainInstanceMessage.AgentSupervisor, pid)

      # Row should still exist
      wait_until(fn -> not is_nil(KindSnapshot.get(uri_str)) end, 100)
      assert %KindSnapshot{kind_type: "agent"} = KindSnapshot.get(uri_str)
    end
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
end
