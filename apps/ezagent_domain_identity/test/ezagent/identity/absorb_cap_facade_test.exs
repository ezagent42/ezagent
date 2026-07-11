defmodule Ezagent.Identity.AbsorbCapFacadeTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Capability

  test "I12 absorb is a prompt cast that buffers on a not-ready grantee and self-stores later" do
    unique = System.unique_integer([:positive])
    user_uri = Ezagent.URI.user("team-alpha", "absorb-not-ready-#{unique}")
    issuer = Ezagent.URI.user("team-alpha", "issuer-#{unique}")

    {:ok, _user} = Ezagent.Users.create(user_uri, nil, [])
    {:ok, pid} = Ezagent.SpawnRegistry.spawn(user_uri)

    on_exit(fn ->
      _ = Ezagent.PendingDelivery.flush(user_uri)
      if Process.alive?(pid), do: Ezagent.Kind.terminate(user_uri)
    end)

    artifact = %Capability{
      kind: :user,
      behavior: Ezagent.ActionSet.Identity,
      action: :list_caps,
      instance: Ezagent.URI.instance(user_uri),
      workspace_uri: Ezagent.Capability.workspace_of(user_uri),
      granted_by: issuer,
      granted_at: DateTime.utc_now()
    }

    :ok = Ezagent.ReadyGate.put(user_uri, :not_ready)
    buffer_size_before = Ezagent.PendingDelivery.buffer_size(user_uri)

    queried_target = Ezagent.URI.with_action(user_uri, :identity, :list_caps)
    task = Task.async(fn -> Ezagent.Identity.absorb_cap(queried_target, artifact) end)

    assert {:ok, :ok} = Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill)
    assert Ezagent.PendingDelivery.buffer_size(user_uri) == buffer_size_before + 1

    assert {:ok, before_slice} = Ezagent.Kind.get_slice(user_uri, :identity)
    before_caps = before_slice |> Ezagent.Kind.normalize_slice_view() |> Map.fetch!(:caps)
    refute Enum.member?(before_caps, artifact)

    assert :ready =
             Ezagent.Kind.ReadyTransition.drain_pending_then_mark_ready(
               URI.to_string(user_uri),
               pid
             )

    assert eventually(fn ->
             with {:ok, slice} <- Ezagent.Kind.get_slice(user_uri, :identity) do
               caps = slice |> Ezagent.Kind.normalize_slice_view() |> Map.fetch!(:caps)
               Enum.member?(caps, artifact)
             else
               _ -> false
             end
           end)
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
