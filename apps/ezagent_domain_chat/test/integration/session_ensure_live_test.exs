defmodule EzagentDomainChat.Integration.SessionEnsureLiveTest do
  @moduledoc """
  Regression for the cold-restart rehydrate gap (Allen 2026-06-03 — live
  传话游戏 e2e). After a node restart, a durably-created session is NOT a
  live actor until something spawns it; the Feishu inbound dispatcher
  resolved a chat→session binding then dispatched WITHOUT ensuring the
  session was live → `:no_such_actor` (the relay session `s34full`).

  `Ezagent.SpawnRegistry.ensure_live/1` (team-routing-unification §3.8
  rehydrate-or-spawn) is the sanctioned fix the dispatcher now calls:
  cold-but-durable → rehydrate; never-created → refuse (no silent fresh
  unowned session). Fixtures use the canonical `Ezagent.URI.new!/1`.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.{KindRegistry, SpawnRegistry}
  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.Entity.Session

  defp session_uri do
    Ezagent.URI.new!("session://default/team-alpha/ensure-live-#{System.unique_integer([:positive])}")
  end

  defp wait_until(fun, tries \\ 50)
  defp wait_until(_fun, 0), do: flunk("condition not met in time")
  defp wait_until(fun, tries), do: if(fun.(), do: :ok, else: (Process.sleep(20); wait_until(fun, tries - 1)))

  test "ensure_live refuses a session that was never durably created" do
    uri = session_uri()
    :ok = KindSnapshot.delete(URI.to_string(uri))

    assert :error = KindRegistry.lookup(uri)
    assert {:error, :not_created} = SpawnRegistry.ensure_live(uri)
    # still not live — it must NOT silently materialise a fresh unowned one
    assert :error = KindRegistry.lookup(uri)
  end

  test "ensure_live returns :live for an already-live session" do
    uri = session_uri()
    {:ok, _pid} = Ezagent.Kind.spawn(Session, %{uri: uri})
    wait_until(fn -> match?({:ok, _}, KindRegistry.lookup(uri)) end)

    assert {:ok, :live} = SpawnRegistry.ensure_live(uri)
  end

  test "ensure_live rehydrates a durably-created-but-cold session" do
    uri = session_uri()
    uri_str = URI.to_string(uri)

    # Create it (production session spawn fn writes the initial snapshot +
    # ever_created marker for this {:snapshot, :on_change} Lifecycle Kind).
    {:ok, pid1} = SpawnRegistry.spawn(uri)
    wait_until(fn -> not is_nil(KindSnapshot.get(uri_str)) end)
    assert KindSnapshot.ever_created?(uri_str)

    # Go cold: terminate the process (snapshot row survives) — a node restart
    # leaves exactly this state (durable row, no live actor).
    :ok = DynamicSupervisor.terminate_child(EzagentDomainChat.SessionSupervisor, pid1)
    wait_until(fn -> KindRegistry.lookup(uri) == :error end)

    # The fix: ensure_live rehydrates it instead of leaving it cold
    # (which is what made the inbound dispatch fail :no_such_actor).
    assert {:ok, :rehydrated} = SpawnRegistry.ensure_live(uri)
    assert {:ok, _pid2} = KindRegistry.lookup(uri)
  end
end
