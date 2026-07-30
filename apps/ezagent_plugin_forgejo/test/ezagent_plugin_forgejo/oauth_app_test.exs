defmodule EzagentPluginForgejo.OAuthAppTest do
  use ExUnit.Case, async: false

  alias EzagentPluginForgejo.OAuthApp

  @ws "workspace://acme"
  @other_ws "workspace://globex"
  @host "code.hyprial.test"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
    :ok
  end

  defp register!(attrs \\ %{}) do
    defaults = %{
      workspace_uri: @ws,
      governed_host: @host,
      client_id: "client-abc",
      client_secret: "secret-xyz",
      redirect_uri: "https://ezagent.test/forgejo/callback"
    }

    OAuthApp.register(Map.merge(defaults, attrs))
  end

  describe "register/1 and fetch/2" do
    test "a registered app is fetched back with its credentials" do
      assert {:ok, _record} = register!()

      assert {:ok, app} = OAuthApp.fetch(@ws, @host)
      assert app.host == @host
      assert app.client_id == "client-abc"
      assert app.client_secret == "secret-xyz"
      assert app.redirect_uri == "https://ezagent.test/forgejo/callback"
    end

    test "fetching an unregistered instance is a miss, not a crash" do
      assert {:error, :oauth_app_not_registered} = OAuthApp.fetch(@ws, "nope.test")
    end

    # The whole reason this table exists: one Ezagent node serves several
    # self-hosted instances, each its own OAuth provider.
    test "two instances in one workspace keep separate credentials" do
      assert {:ok, _} = register!()
      assert {:ok, _} = register!(%{governed_host: "git.other.test", client_id: "client-other"})

      assert {:ok, %{client_id: "client-abc"}} = OAuthApp.fetch(@ws, @host)
      assert {:ok, %{client_id: "client-other"}} = OAuthApp.fetch(@ws, "git.other.test")
    end

    # Tenant isolation (invariant 14). If this regresses, one tenant's
    # authorization flow runs under another tenant's client credentials.
    test "another workspace cannot fetch this workspace's app" do
      assert {:ok, _} = register!()
      assert {:error, :oauth_app_not_registered} = OAuthApp.fetch(@other_ws, @host)
    end

    test "the same host registered in two workspaces stays separate" do
      assert {:ok, _} = register!()
      assert {:ok, _} = register!(%{workspace_uri: @other_ws, client_id: "client-globex"})

      assert {:ok, %{client_id: "client-abc"}} = OAuthApp.fetch(@ws, @host)
      assert {:ok, %{client_id: "client-globex"}} = OAuthApp.fetch(@other_ws, @host)
    end

    test "re-registering the same instance replaces the credentials" do
      assert {:ok, _} = register!()
      assert {:ok, _} = register!(%{client_id: "rotated", client_secret: "rotated-secret"})

      assert {:ok, app} = OAuthApp.fetch(@ws, @host)
      assert app.client_id == "rotated"
      assert app.client_secret == "rotated-secret"
    end
  end

  describe "secret handling" do
    test "the client secret is not readable from the stored row" do
      assert {:ok, _} = register!()

      stored =
        EzagentCore.Repo.all(OAuthApp.Record)
        |> :erlang.term_to_binary()

      refute stored =~ "secret-xyz"
    end
  end

  describe "validation" do
    test "a malformed host is refused at registration, not at request time" do
      assert {:error, :invalid_provider_host} = register!(%{governed_host: "https://evil.test"})
    end

    test "a blank client id is refused" do
      assert {:error, :invalid_client_id} = register!(%{client_id: ""})
    end

    test "a blank client secret is refused" do
      assert {:error, :invalid_client_secret} = register!(%{client_secret: ""})
    end

    # A redirect_uri is where the provider sends an authorization code. A
    # non-absolute one would silently misroute it.
    test "a non-absolute redirect uri is refused" do
      assert {:error, :invalid_redirect_uri} = register!(%{redirect_uri: "/forgejo/callback"})
    end

    test "a workspace uri that is not a workspace URI is refused" do
      assert {:error, :invalid_workspace_uri} =
               register!(%{workspace_uri: "entity://acme/user/x"})
    end
  end
end
