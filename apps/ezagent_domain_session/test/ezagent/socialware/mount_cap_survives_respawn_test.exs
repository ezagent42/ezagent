defmodule Ezagent.Socialware.MountCapSurvivesRespawnTest do
  @moduledoc """
  A4 investigation — does a runtime-minted mount cap survive a real cold respawn
  of its grantee, WITHOUT `reconcile_session_mounts` re-minting it?

  `reconcile_session_mounts/1`'s stated premise (mount.ex doc) is that on restart
  the grantee's cap slice is "rebuilt WITHOUT re-minting", so the mount keys are
  lost and must be re-minted from the `MountRow` ledger. Post-#195 caps are
  durable (absorb → persist to `users.caps_json` / agent snapshot), so a cold
  rebuild should re-read them. This test settles it empirically: mount, then
  terminate + cold-respawn the grantee, then check the cap is STILL held —
  with NO reconcile call in between.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Socialware.Mount
  alias EzagentDomainInstanceMessage.CompositionGrantTargetBehavior, as: Target

  test "mount cap survives a cold grantee respawn with NO reconcile (cap-as-truth)" do
    owner = user_uri("survive-owner")
    grantee = live_agent("survive-grantee", owner, [Target])
    target = live_agent("survive-board", owner, [Target])
    session = session_uri()

    # (1) mount → grantee holds the operate cap
    assert {:ok, _} =
             Mount.mount(session, target, grantee, Target, [:add_node, :get_tree],
               access: :operate
             )

    assert eventually(fn -> holds_cap?(grantee, target, :add_node) end)

    # (2) durable proof: the runtime-minted cap is in the grantee's DURABLE store
    # (not just the live process) — read it without touching the live slice.
    assert durable_holds_cap?(grantee, target, :add_node),
           "runtime-minted mount cap was not persisted durably"

    # (3) COLD respawn: terminate the grantee Kind, then re-read via the durable/
    # rehydrating read path. NO reconcile_session_mounts is called.
    :ok = Ezagent.Kind.terminate(grantee)
    refute Ezagent.Kind.alive?(grantee)

    # (4) after cold rehydrate the cap is STILL held → reconcile was redundant
    assert eventually(fn -> holds_cap?(grantee, target, :add_node) end),
           "mount cap did NOT survive cold respawn — reconcile is NOT redundant"

    assert holds_cap?(grantee, target, :get_tree)
  end

  # --- helpers (subset of mount_reconcile_test) ----------------------------

  defp durable_holds_cap?(grantee, target, action) do
    # EntityCaps.load reads the durable store (users.caps_json / agent snapshot)
    # — the same source list_caps_for uses — without depending on a live process.
    grantee
    |> Ezagent.EntityCaps.load()
    |> Enum.any?(&cap_matches?(&1, target, action))
  end

  defp holds_cap?(grantee, target, action) do
    Enum.any?(Ezagent.Identity.list_caps_for(grantee), &cap_matches?(&1, target, action))
  end

  defp cap_matches?(cap, target, action) do
    cap.kind == :agent and cap.behavior == Target and cap.action == action and
      cap.instance == Ezagent.URI.instance(target)
  end

  defp live_agent(name, owner, extra_behaviors) do
    uri = agent_uri(name)
    behaviors = Enum.uniq(Ezagent.Entity.Agent.base_behaviors() ++ extra_behaviors)

    {:ok, _pid} =
      Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{
        uri: uri,
        behaviors: behaviors,
        creator_uri: owner,
        initial_caps: MapSet.new()
      })

    :ok = Ezagent.WorkspaceRegistry.bind(uri, Ezagent.URI.workspace("composition"))
    :ok = Ezagent.AgentLineage.record(uri, owner)
    on_exit(fn -> Ezagent.Kind.terminate(uri) end)
    uri
  end

  defp eventually(fun, attempts \\ 50)
  defp eventually(fun, attempts) when attempts <= 1, do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp uniq, do: System.unique_integer([:positive])

  defp session_uri, do: Ezagent.URI.new!("session://composition/default/survive-#{uniq()}")

  defp user_uri(name) do
    uri = Ezagent.URI.new!("entity://composition/user/#{name}-#{uniq()}")
    {:ok, _} = Ezagent.Users.create(uri, "test-password-#{uniq()}", [])
    {:ok, _} = Ezagent.SpawnRegistry.spawn(uri)
    on_exit(fn -> Ezagent.Kind.terminate(uri) end)
    uri
  end

  defp agent_uri(name), do: Ezagent.URI.new!("entity://composition/agent/#{name}-#{uniq()}")
end
