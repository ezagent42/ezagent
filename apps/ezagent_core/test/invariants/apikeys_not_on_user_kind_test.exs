defmodule EzagentCore.Invariants.ApiKeysNotOnUserKindTest do
  @moduledoc """
  Invariant test for the 2026-05-26 ApiKeys-to-Agent flip.

  Allen directive: agents hold their own outbound API credentials;
  users do NOT. Re-introducing `Ezagent.Behavior.ApiKeys` on the User
  Kind would resurrect the per-user credential bag the flip
  dismantled — every CurlAgent would again default to
  `entity://system/user/admin`'s key, every workspace clone would
  leak the operator's secrets, and the per-agent permission model
  (creator + admin) would collapse back into "whoever owns this user
  can mint outbound calls anywhere".

  This test fails LOUD on any of the structural backslides:

  1. `Ezagent.Behavior.ApiKeys` listed in `Ezagent.Entity.User.behaviors/0`
  2. `CapabilityRegistry.subjects_for_kind(Ezagent.Entity.User)` includes
     an `ApiKeys` subject
  3. `BehaviorRegistry.lookup(Ezagent.Entity.User, :get_api_key)`
     resolves to ApiKeys (any of the four actions counts).

  Mirrors the structural pattern of
  `agent_create_single_path_test.exs` and other invariant tests —
  one canonical entry point, one assertion shape, fast on a cold
  boot.
  """

  use ExUnit.Case, async: false

  # #52 Mode-A: cross-tier suite — references sibling-app modules; resolves
  # only in the umbrella. Excluded standalone (`cd apps/ezagent_core && mix test`).
  @moduletag :umbrella_only

  alias Ezagent.{BehaviorRegistry, CapabilityRegistry}
  alias Ezagent.Behavior.ApiKeys
  alias Ezagent.Entity.User

  test "User.behaviors/0 must NOT list Behavior.ApiKeys" do
    refute ApiKeys in User.behaviors(),
           "Allen 2026-05-26 flipped ApiKeys from User Kind to Agent Kind. " <>
             "Re-adding it to `Ezagent.Entity.User.behaviors/0` resurrects " <>
             "the per-user credential bag. Move the cap subject to " <>
             "`Ezagent.Entity.Agent` / `Ezagent.Entity.CurlAgent`."
  end

  test "CapabilityRegistry.subjects_for_kind(User) must not name ApiKeys as a subject" do
    leaking =
      User
      |> CapabilityRegistry.subjects_for_kind()
      |> Enum.filter(fn %{behavior: b} -> b == ApiKeys end)

    assert leaking == [],
           "Behavior.ApiKeys is registered against User Kind in CapabilityRegistry. " <>
             "Allen 2026-05-26 flip: registration must be on `Ezagent.Entity.Agent` " <>
             "(in `EzagentDomainIdentity.Application`) and `Ezagent.Entity.CurlAgent` " <>
             "(in `EzagentPluginCurlAgent.Application`). Found subjects: " <>
             inspect(leaking)
  end

  test "BehaviorRegistry.lookup(User, <ApiKeys action>) must NOT resolve to ApiKeys" do
    for action <- ApiKeys.actions() do
      case BehaviorRegistry.lookup(User, action) do
        {:ok, ApiKeys} ->
          flunk(
            "BehaviorRegistry resolves `User` + `:#{action}` to Behavior.ApiKeys — " <>
              "post-flip User Kind must not dispatch ApiKeys actions. Action: #{action}"
          )

        _ ->
          :ok
      end
    end
  end

  # Codex MED closure (2026-05-26): the negative tests above prove
  # ApiKeys is NOT on User. The positive assertions below prove the
  # flip's destination — without them, an accidental "delete the
  # registration entirely" regression would still pass the negative
  # tests but disable ApiKeys system-wide.

  test "Behavior.ApiKeys IS registered on every supported agent-flavor Kind" do
    # The list mirrors the post-flip registration sites:
    # - identity domain Application registers against Ezagent.Entity.Agent
    # - curl_agent plugin's behaviors/0 publishes against Ezagent.Entity.CurlAgent
    #
    # Test-mode safety: the chat/curl plugins may not be loaded in a
    # bare core-only test run; we skip an agent flavor whose Kind
    # module isn't compiled (no plugin → no Kind → no registration
    # to assert). The assertion still locks the post-flip wiring
    # for any Kind that IS present.
    expected_kinds =
      [Ezagent.Entity.Agent, Ezagent.Entity.CurlAgent]
      |> Enum.filter(&Code.ensure_loaded?/1)

    assert expected_kinds != [],
           "no agent-flavor Kinds compiled — this test asserts post-flip " <>
             "registration but found no Kind to assert against. If running " <>
             "core-only, this test belongs in an umbrella-mode test run."

    for kind <- expected_kinds, action <- ApiKeys.actions() do
      assert {:ok, ApiKeys} = BehaviorRegistry.lookup(kind, action),
             "Post-flip wiring missing: " <>
               "`BehaviorRegistry.lookup(#{inspect(kind)}, #{inspect(action)})` " <>
               "must return `{:ok, Ezagent.Behavior.ApiKeys}`. Allen 2026-05-26 — " <>
               "ApiKeys moved from User Kind to every agent-flavor Kind. Check " <>
               "EzagentDomainIdentity.Application.register_identity_behaviors/0 " <>
               "(Agent) and EzagentPluginCurlAgent.Application.behaviors/0 (CurlAgent)."
    end
  end

  test "every agent-flavor Kind lists Behavior.ApiKeys in its behaviors/0" do
    # Slice init at spawn-time goes through `Kind.behaviors/0`; if a
    # flavor doesn't list ApiKeys here, the `:api_keys` slice is never
    # initialised on that Kind's instance, and `data_owner/1` lookups
    # against `Kind.get_slice/2` return `:error`. Registration alone
    # (above) is insufficient — both axes must line up.
    expected_kinds =
      [Ezagent.Entity.Agent, Ezagent.Entity.CurlAgent]
      |> Enum.filter(&Code.ensure_loaded?/1)

    for kind <- expected_kinds do
      assert ApiKeys in kind.behaviors(),
             "Post-flip slice-init missing: `#{inspect(kind)}.behaviors/0` must " <>
               "include `Ezagent.Behavior.ApiKeys` so the `:api_keys` slice is " <>
               "initialised at spawn. Without this, `data_owner/1` resolves to " <>
               ":no_owner for every instance of this Kind and the non-admin " <>
               "creator-grant path silently fails."
    end
  end
end
