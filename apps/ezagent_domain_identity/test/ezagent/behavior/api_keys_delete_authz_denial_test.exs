defmodule Ezagent.ActionSet.ApiKeysDeleteAuthzDenialTest do
  @moduledoc """
  Security regression for #1582 (agent API-key deletion).

  #1582 added the World delete path `dispatch_api_key_delete/3`
  (`apps/ezagent_plugin_world/lib/ezagent_plugin_world/world_live.ex`),
  which fires a REAL domain dispatch against the agent's ApiKeys behavior:

      Invocation.dispatch(%Invocation{
        target: Ezagent.URI.with_action(agent_uri, :identity, :delete_api_key),
        args: %{provider: provider},
        origin: :authenticated_external,
        ctx: %{caller: caller, authenticated_principal: caller, caps: caps, reply: :sync}
      })

  Delete is Cap-adjacent: the ONLY thing standing between an arbitrary
  caller and another agent's stored credential is the dispatch step-5.5
  cap gate (`Ezagent.Cap.Verifier.authorize/6` → `Ezagent.Cap.Authorize`).
  #1582 shipped that gate, but its own contract test
  (`agent_api_key_delete_contract_test.exs`) asserts the wiring "by
  construction" — a string match on `world_live.ex` plus a handler-level
  unit test. Neither proves the gate DENIES.

  This test drives the SAME real domain chokepoint against the REAL
  `Ezagent.Entity.Agent` Kind (which hosts `Ezagent.ActionSet.ApiKeys`) and
  proves the gate denies a non-owner / non-admin caller who holds no
  `delete_api_key` cap, AND that the denied dispatch leaves the target's
  stored key untouched. The persisted slice is read back via
  `SliceAccess.get_raw_slice/2` — a real persisted-state check, not a
  return-value inspection ("the stored key is UNCHANGED afterward").

  ## Teeth (no throwaway hack)

  Both the denial and the positive control use the SAME non-admin caller,
  varying ONLY the presented cap. The caller is provisioned as an ordinary
  live principal (`Users.create` + `SpawnRegistry.spawn` mints its durable
  self-license, so it passes the `Ezagent.Cap.Authorize` principal gate) but
  holds NO agent capability durably. A non-admin has no wildcard / genesis /
  anchor / admin-materialization path, so the signed `delete_api_key` cap it
  presents on the positive path is the ONLY thing that can authorize the
  delete. The positive control therefore proves — permanently, not via a
  temporary edit — that the denial came from the cap gate and nothing else.

  ## Denial reason atom (reported to the #1582 follow-up)

  At the pure domain level a cap-less-but-live caller is denied with
  `{:error, :missing_cap}` (`Ezagent.Cap.Authorize` returns
  `:no_matching_cap`, collapsed to `:missing_cap` in
  `Ezagent.Cap.Verifier.verify_cap/6` — "no matching grant presented"). The
  World surface treats `:missing_cap` and `:unauthorized` as the SAME
  authz-denial class (`world_live.ex`:
  `reason when reason in [:missing_cap, :unauthorized]`), which is why the
  operator sees "unauthorized". We assert membership in that class so the
  test pins a CAP-GATE denial and rejects a denial from the WRONG place
  (`:holder_revoked` / `:no_such_actor` / `:invalid_args` /
  `:presenter_mismatch` / `{:unknown_action, _}`).
  """

  use EzagentCore.DataCase, async: false

  import Ezagent.Test.CapHelper, only: [signed_invocation!: 2, signed_required_cap!: 5]

  alias Ezagent.ActionSet.ApiKeys
  alias Ezagent.Entity.Agent
  alias Ezagent.Invocation

  @denial_reasons [:missing_cap, :unauthorized]

  # ----------------------------------------------------------------------
  # Fixtures
  # ----------------------------------------------------------------------

  # Spawn the REAL Agent Kind (hosts ApiKeys) and workspace-bind it, exactly
  # like config_evolve_test.exs — the Kind #1582's World path deletes keys on.
  defp spawn_agent! do
    name = "apikey-denial-#{System.unique_integer([:positive])}"
    agent = Ezagent.URI.entity(:team_alpha, :agent, name)
    {:ok, _pid} = Ezagent.Kind.spawn(Agent, %{uri: agent, initial_caps: []})
    :ok = Ezagent.WorkspaceRegistry.bind(agent, Ezagent.Capability.workspace_of(agent))
    on_exit(fn -> Ezagent.Kind.terminate(agent) end)
    agent
  end

  # An ordinary live principal that holds NO agent capability durably. The
  # `Users.create` + `SpawnRegistry.spawn` pair mints the durable
  # current-generation self-license that lets it pass the `Cap.Authorize`
  # principal gate (an unspawned/never-created user would fail closed as
  # `:holder_revoked`, which is a DIFFERENT denial than "lacks the cap").
  defp provision_caller!(label) do
    caller =
      Ezagent.URI.entity(:team_alpha, :user, "#{label}-#{System.unique_integer([:positive])}")

    {:ok, _user} = Ezagent.Users.create(caller, nil, [])
    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(caller)
    caller
  end

  defp target(agent, action), do: Ezagent.URI.with_action(agent, :identity, action)

  # A concrete, target-signed cap for `action`, issued to `grantee`.
  defp cap_for(agent, action, grantee),
    do: signed_required_cap!(target(agent, action), :agent, ApiKeys, action, grantee)

  # Build the dispatch shape #1582 ships (`origin: :authenticated_external`,
  # `mode: :call`, `reply: :sync`), sign the ctx against the Agent's live
  # generation, and dispatch.
  defp dispatch(agent, action, args, caller, caps) do
    %Invocation{
      origin: :authenticated_external,
      target: target(agent, action),
      mode: :call,
      args: args,
      ctx: %{caller: caller, caps: MapSet.new(caps), reply: :sync}
    }
    |> signed_invocation!(:agent)
    |> Invocation.dispatch()
  end

  defp stored_keys(agent) do
    {:ok, %{state: %{keys: keys}}} = Ezagent.Kind.SliceAccess.get_raw_slice(agent, :api_keys)
    keys
  end

  # ----------------------------------------------------------------------
  # Tests
  # ----------------------------------------------------------------------

  test "a non-owner without the delete cap CANNOT delete an agent API key; the SAME caller WITH it can" do
    agent = spawn_agent!()
    caller = provision_caller!("keyholder")

    # Seed a key via an authorized put by `caller` (presents ONLY the put
    # cap). Also proves `identity.put_api_key` resolves to ApiKeys by ACTION.
    assert {:ok, %{ok: true, provider: "deepseek"}} =
             dispatch(
               agent,
               :put_api_key,
               %{provider: "deepseek", key: "sk-victim-secret-0001"},
               caller,
               [cap_for(agent, :put_api_key, caller)]
             )

    assert stored_keys(agent) == %{"deepseek" => "sk-victim-secret-0001"}

    # DENIAL: the SAME live caller, EMPTY presented caps → the step-5.5 cap
    # gate must deny, and the stored key must be UNCHANGED.
    assert {:error, reason} =
             dispatch(agent, :delete_api_key, %{provider: "deepseek"}, caller, [])

    assert reason in @denial_reasons,
           "delete_api_key by a cap-less caller must be denied by the step-5.5 cap gate, " <>
             "got: #{inspect(reason)}"

    assert stored_keys(agent) == %{"deepseek" => "sk-victim-secret-0001"},
           "a DENIED delete must not mutate the target's stored key"

    # TEETH (permanent, not a throwaway edit): the SAME non-admin caller, now
    # presenting the delete cap, deletes the key. The delete cap is the ONLY
    # difference from the denied dispatch above — so the denial was the cap
    # gate and nothing else.
    assert {:ok, %{ok: true, provider: "deepseek"}} =
             dispatch(
               agent,
               :delete_api_key,
               %{provider: "deepseek"},
               caller,
               [cap_for(agent, :delete_api_key, caller)]
             )

    refute Map.has_key?(stored_keys(agent), "deepseek"),
           "with the delete cap present the same dispatch must delete the key"
  end

  test "presenting a DIFFERENT-action ApiKeys cap (get, not delete) does NOT authorize delete" do
    agent = spawn_agent!()
    caller = provision_caller!("wrongcap")

    assert {:ok, %{ok: true, provider: "openai"}} =
             dispatch(
               agent,
               :put_api_key,
               %{provider: "openai", key: "sk-openai-secret-0002"},
               caller,
               [cap_for(agent, :put_api_key, caller)]
             )

    # A real, target-signed ApiKeys cap issued to `caller` — but the WRONG
    # action axis (get). It must not satisfy the delete action's required cap.
    assert {:error, reason} =
             dispatch(
               agent,
               :delete_api_key,
               %{provider: "openai"},
               caller,
               [cap_for(agent, :get_api_key, caller)]
             )

    assert reason in @denial_reasons,
           "a get_api_key cap must not satisfy the delete_api_key action gate, got: #{inspect(reason)}"

    assert stored_keys(agent) == %{"openai" => "sk-openai-secret-0002"},
           "a DENIED delete must not mutate the target's stored key"
  end
end
