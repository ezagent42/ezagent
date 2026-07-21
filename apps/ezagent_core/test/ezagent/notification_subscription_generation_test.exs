defmodule Ezagent.NotificationSubscriptionGenerationTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Cap.Authority
  alias Ezagent.Capability
  alias Ezagent.NotificationSubscriptions, as: Subs

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

  test "a bumped notification stream rejects its dormant subscribe cap" do
    n = System.unique_integer([:positive])
    holder = Ezagent.URI.new!("entity://acme/user/subscriber-#{n}")
    stream = Ezagent.URI.new!("entity://acme/user/stream-#{n}")
    {:ok, authority} = Authority.open(stream, :user)

    cap =
      %Capability{
        kind: :user,
        behavior: Ezagent.ActionSet.Notifications,
        action: :subscribe,
        instance: stream,
        workspace_uri: Capability.workspace_of(stream),
        granted_by: holder,
        granted_at: DateTime.utc_now(),
        grantee_uri: holder
      }
      |> then(&Authority.sign(authority, &1))

    Application.put_env(:ezagent_core, EzagentCore.Test.CapAuthorityLoaderStub, %{
      Ezagent.URI.stable_key(holder) => MapSet.new([cap])
    })

    ctx = %{
      caller: holder,
      authenticated_principal: holder,
      caps: MapSet.new([cap])
    }

    assert :ok = Subs.register_subscription(holder, stream, ctx)
    assert {:ok, _} = Authority.regenesis(stream, :user, admin())
    assert {:error, :unauthorized} = Subs.register_subscription(holder, stream, ctx)
  end

  defp admin, do: Ezagent.URI.user(:system, :admin)
end
