defmodule Ezagent.AgentBridge.RecredentialGenerationTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.AgentBridge.TokenStore

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "ezagent-bridge-recredential-#{System.unique_integer([:positive])}"
      )

    prior_home = System.get_env("EZAGENT_HOME")
    prior_profile = System.get_env("EZAGENT_PROFILE")
    System.put_env("EZAGENT_HOME", root)
    System.put_env("EZAGENT_PROFILE", "test")

    on_exit(fn ->
      if prior_home,
        do: System.put_env("EZAGENT_HOME", prior_home),
        else: System.delete_env("EZAGENT_HOME")

      if prior_profile,
        do: System.put_env("EZAGENT_PROFILE", prior_profile),
        else: System.delete_env("EZAGENT_PROFILE")

      File.rm_rf!(root)
    end)

    :ok
  end

  test "a genuine generation-N recreate rotates the stale bridge token" do
    uri =
      Ezagent.URI.agent(
        "team-alpha",
        "bridge-recreate-#{System.unique_integer([:positive])}"
      )

    assert :ok = Ezagent.IdentityCaps.Store.initialize(uri, [])
    assert {:ok, first_authority} = Ezagent.Cap.Authority.open(uri, :agent)
    assert {:ok, stale_token} = TokenStore.mint(uri)

    assert {:ok, second_authority} = Ezagent.Cap.Authority.regenesis(uri, :agent)
    assert second_authority.generation == first_authority.generation + 1

    # A standalone bump cannot re-arm the principal.
    assert {:error, :principal_revoked} = TokenStore.mint(uri)

    # No Lifecycle marker exists yet, so this is the genuine create/reprovision
    # seam. The Kind opens directly on the already-active generation N.
    assert {:ok, pid} =
             Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{
               uri: uri,
               creator_uri: Ezagent.Entity.User.admin_uri(),
               initial_caps: MapSet.new()
             })

    on_exit(fn -> Ezagent.Kind.terminate(uri) end)

    assert :created = :sys.get_state(pid).create_freshness
    assert {:ok, fresh_token} = TokenStore.mint(uri)
    refute fresh_token == stale_token
    refute TokenStore.verify_token(uri, stale_token)
    assert TokenStore.verify_token(uri, fresh_token)

    assert [{^uri, %{"bound_generation" => generation}}] = TokenStore.list_all()
    assert generation == second_authority.generation
  end
end
