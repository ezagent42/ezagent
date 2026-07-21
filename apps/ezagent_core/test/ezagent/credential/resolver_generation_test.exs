defmodule Ezagent.Credential.ResolverGenerationTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Cap.Authority
  alias Ezagent.Credential.Resolver

  setup do
    previous = Application.get_env(:ezagent_core, Ezagent.Cap, [])

    Application.put_env(
      :ezagent_core,
      Ezagent.Cap,
      Keyword.put(previous, :authority_loader, EzagentCore.Test.CapAuthorityLoaderStub)
    )

    on_exit(fn -> Application.put_env(:ezagent_core, Ezagent.Cap, previous) end)
    :ok
  end

  test "a bumped credential source rejects its dormant sandbox.read cap" do
    n = System.unique_integer([:positive])
    holder = Ezagent.URI.new!("entity://team-a/user/credential-reader-#{n}")
    source = Ezagent.URI.new!("entity://team-a/agent/credential-source-#{n}")
    {:ok, authority} = Authority.open(source, :agent)

    cap =
      source
      |> Ezagent.Credential.GrantCap.read_cap_for()
      |> Map.merge(%{
        granted_by: holder,
        granted_at: DateTime.utc_now(),
        grantee_uri: holder
      })
      |> then(&Authority.sign(authority, &1))

    Application.put_env(:ezagent_core, EzagentCore.Test.CapAuthorityLoaderStub, %{
      Ezagent.URI.stable_key(holder) => MapSet.new([cap])
    })

    assert Resolver.source_read_authorized?(holder, source, [cap])
    assert {:ok, _} = Authority.regenesis(source, :agent, admin())
    refute Resolver.source_read_authorized?(holder, source, [cap])
  end

  defp admin, do: Ezagent.URI.user(:system, :admin)
end
