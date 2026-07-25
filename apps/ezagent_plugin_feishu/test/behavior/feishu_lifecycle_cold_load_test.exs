defmodule EzagentPluginFeishu.Behavior.FeishuLifecycleColdLoadTest do
  @moduledoc """
  Phase B (2026-05-29) Lifecycle migration — cold-load round-trip gate
  for the two converted Feishu Behaviors (both the simple no-transients
  case):

  - `EzagentPluginFeishu.Behavior.ExternalAdapter.Feishu.Allow` —
    cap-only marker (`dispatchable?/0 == false`), empty `state`.
  - `EzagentPluginFeishu.Behavior.UserBinding` — incidental `bind_count`
    counter in `state`; the DB table is the real SSOT.

  SPEC `docs/superpowers/specs/2026-05-29-lifecycle-hooks-design.md` §6:
  `assert_transients_rebuilt/2` is N/A (no transients). The architectural
  property a no-transients module MUST pin is the OTHER half of the
  two-container contract:

    `create/1` → PERSISTENT `state` → snapshot → cold-load REHYDRATES it
    (and `create/1` does NOT re-run on the cold-load — the ever-created
    marker gates it), and `transients` stays EMPTY across the restart.

  ## Why test-only `{:snapshot, :on_change}` Kinds

  Both Behaviors are registered in production on long-lived core Kinds
  (Session for Allow, Workspace for UserBinding). To exercise the
  persistent-state half of the Lifecycle contract in isolation we host
  the unchanged Behaviors on test-only Kinds with `{:snapshot,
  :on_change}` (the same technique the reference
  `Ezagent.ActionSet.SandboxColdRestartTest` + the curl-agent /
  echo cold-load gates use).
  """

  use EzagentCore.DataCase, async: false

  alias EzagentPluginFeishu.Behavior.ExternalAdapter.Feishu.Allow
  alias EzagentPluginFeishu.Behavior.UserBinding
  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.{Kind, KindRegistry}

  defmodule FeishuAllowColdLoadKind do
    @moduledoc false
    @behaviour Ezagent.Kind
    @impl Ezagent.Kind
    def type_name, do: :feishu_allow_cold_load
    @impl Ezagent.Kind
    def behaviors, do: [Allow]
    @impl Ezagent.Kind
    def persistence, do: {:snapshot, :on_change}
  end

  defmodule UserBindingColdLoadKind do
    @moduledoc false
    @behaviour Ezagent.Kind
    @impl Ezagent.Kind
    def type_name, do: :feishu_user_binding_cold_load
    @impl Ezagent.Kind
    def behaviors, do: [UserBinding]
    @impl Ezagent.Kind
    def persistence, do: {:snapshot, :on_change}
  end

  setup_all do
    Code.ensure_loaded!(Allow)
    Code.ensure_loaded!(UserBinding)
    Code.ensure_loaded!(FeishuAllowColdLoadKind)
    Code.ensure_loaded!(UserBindingColdLoadKind)
    :ok
  end

  defp wait_until(fun, attempts \\ 100)
  defp wait_until(_fun, 0), do: flunk("wait_until: condition never became true")

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end

  # Generic no-transients cold-load round-trip: spawn → assert state +
  # ever-created marker persisted → terminate → respawn → assert state
  # rehydrated unchanged (create-once) + transients still empty.
  defp assert_cold_load_round_trips(kind, type, slice_key, expected_state) do
    uri = URI.new!("system://#{type}/inst-#{System.unique_integer([:positive])}")
    uri_str = URI.to_string(uri)

    {:ok, pid1} = Kind.spawn(kind, %{uri: uri})
    wait_until(fn -> Ezagent.ReadyGate.status(uri) == :ready end)

    # T3: RAW read — assert on both containers.
    {:ok, %{state: state_before, transients: transients_before}} =
      Ezagent.Kind.SliceAccess.get_raw_slice(uri, slice_key)

    assert state_before == expected_state
    assert transients_before == %{}

    assert %KindSnapshot{} = KindSnapshot.get(uri_str)
    assert KindSnapshot.ever_created?(uri_str)

    # Permanent termination; the durable snapshot survives.
    ref = Process.monitor(pid1)
    :ok = Kind.terminate(uri)
    assert_receive {:DOWN, ^ref, :process, ^pid1, _}, 2_000
    wait_until(fn -> KindRegistry.lookup(uri_str) == :error end)

    assert KindSnapshot.ever_created?(uri_str)

    # Cold-load — re-spawn. ever_created? true → create/1 SKIPPED; the
    # snapshot merge rehydrates state.
    {:ok, pid2} = Kind.spawn(kind, %{uri: uri})
    refute pid1 == pid2
    wait_until(fn -> Ezagent.ReadyGate.status(uri) == :ready end)

    {:ok, %{state: state_after, transients: transients_after}} =
      Ezagent.Kind.SliceAccess.get_raw_slice(uri, slice_key)

    # State rehydrated correctly; create/1 did NOT re-run; no transients.
    assert state_after == state_before
    assert transients_after == %{}

    Kind.terminate(uri)
  end

  test "FeishuAllow create→state (empty marker) round-trips through a cold-load" do
    assert_cold_load_round_trips(
      FeishuAllowColdLoadKind,
      "feishu_allow_cold_load",
      :external_adapter_feishu,
      %{}
    )
  end

  test "UserBinding create→state (bind_count counter) round-trips through a cold-load" do
    assert_cold_load_round_trips(
      UserBindingColdLoadKind,
      "feishu_user_binding_cold_load",
      :feishu_user_bindings,
      %{bind_count: 0}
    )
  end
end
