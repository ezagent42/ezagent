defmodule EzagentCore.Invariants.ApiKeysNotOnUserKindTest do
  @moduledoc """
  Invariant test for the 2026-05-26 ApiKeys-to-Agent flip.

  Allen directive: agents hold their own outbound API credentials;
  users do NOT. Re-introducing `Ezagent.Behavior.ApiKeys` on the User
  Kind would resurrect the per-user credential bag the flip
  dismantled — every CurlAgent would again default to
  `entity://user/system/admin`'s key, every workspace clone would
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
end
