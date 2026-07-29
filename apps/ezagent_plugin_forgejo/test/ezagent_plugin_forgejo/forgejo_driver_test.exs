defmodule EzagentPluginForgejo.ForgejoDriverTest do
  use ExUnit.Case, async: false

  alias EzagentPluginForgejo.{ForgejoDriver, OAuthApp}

  @stub_name :forgejo_driver_test
  @ws "workspace://acme"
  @host "code.hyprial.test"
  @verifier "dBjftJeZ4CVPmB92K27uhbUJU1p1r_wW1gFWFOEjXk"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)

    {:ok, _} =
      OAuthApp.register(%{
        workspace_uri: @ws,
        governed_host: @host,
        client_id: "client-abc",
        client_secret: "secret-xyz",
        redirect_uri: "https://ezagent.test/forgejo/callback"
      })

    :ok
  end

  # Mirrors what the domain hands a driver: an `exchange` closure that yields
  # the private frame, merged with the driver-identity keys.
  defp context(private_frame, overrides \\ %{}) do
    Map.merge(
      %{
        exchange: fn fun -> fun.(private_frame) end,
        workspace_uri: @ws,
        governed_host: @host,
        owner_uri: "entity://acme/user/dev",
        provider_id: "forgejo",
        acquisition_method: "oauth_user",
        correlation_id: "corr-1",
        authorization_ref: "auth-ref-1",
        expected_authorization_version: 0
      },
      overrides
    )
  end

  defp frame(overrides \\ %{}) do
    Map.merge(%{state: "state-123", pkce_verifier: @verifier, callback_envelope: %{}}, overrides)
  end

  # Injection uses the seam this codebase already has for provider HTTP —
  # `:adapter_req_opts`, the same key live E2E uses to pass a proxy — rather
  # than a test-only key smuggled through the driver context. On_exit restores
  # it so one test cannot silently stub another.

  defp stub(fun) do
    Req.Test.stub(@stub_name, fun)
    previous = Application.get_env(:ezagent_plugin_forgejo, :adapter_req_opts)
    Application.put_env(:ezagent_plugin_forgejo, :adapter_req_opts, plug: {Req.Test, @stub_name})

    ExUnit.Callbacks.on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:ezagent_plugin_forgejo, :adapter_req_opts)
        value -> Application.put_env(:ezagent_plugin_forgejo, :adapter_req_opts, value)
      end
    end)

    :ok
  end

  describe "begin_authorization/1" do
    test "returns a redirect to the tenant's own instance" do
      assert {:ok, %{redirect: redirect}} =
               ForgejoDriver.begin_authorization(context(frame()))

      uri = URI.parse(redirect["authorization_uri"])
      assert uri.host == @host
      assert uri.path == "/login/oauth/authorize"
      assert redirect["state"] == "state-123"
    end

    test "publishes the PKCE digest, never the verifier" do
      assert {:ok, %{redirect: redirect}} =
               ForgejoDriver.begin_authorization(context(frame()))

      expected = :crypto.hash(:sha256, @verifier) |> Base.url_encode64(padding: false)
      assert redirect["pkce_digest"] == expected
      refute redirect["authorization_uri"] =~ @verifier
    end

    # Without a registered app there is no client_id to authorize with. Failing
    # closed beats redirecting the user somewhere half-formed.
    test "an unregistered instance fails closed" do
      assert {:error, :provider_protocol_failed} =
               ForgejoDriver.begin_authorization(context(frame(), %{governed_host: "nope.test"}))
    end

    test "a context without an exchange closure is a protocol failure" do
      assert {:error, :provider_protocol_failed} = ForgejoDriver.begin_authorization(%{})
    end
  end

  describe "consume_callback/1" do
    setup do
      stub(fn conn ->
        case conn.request_path do
          "/login/oauth/access_token" ->
            Req.Test.json(conn, %{
              "access_token" => "at-1",
              "refresh_token" => "rt-1",
              "expires_in" => 3600
            })

          "/api/v1/user" ->
            Req.Test.json(conn, %{"id" => 7, "login" => "gagameow"})
        end
      end)
    end

    test "identifies the connected account and hands over the credential" do
      ctx = context(frame(%{callback_envelope: %{code: "the-code"}}))

      assert {:ok, result} = ForgejoDriver.consume_callback(ctx)

      assert result.external_account_id == "7"
      assert result.display_login == "gagameow"
      assert result.execution_identity == %{kind: :connected_user, external_account_id: "7"}
      assert {:write_only_handoff, _material} = result.credential_material
    end

    # Measured: the access token expires in an hour. The domain persists an
    # absolute expiry; leaving it nil (as the GitHub driver does, because its
    # user token has none) would mark an hour-long credential as eternal.
    test "reports the access token's real expiry" do
      ctx = context(frame(%{callback_envelope: %{code: "the-code"}}))

      assert {:ok, %{expires_at: %DateTime{} = expires_at}} = ForgejoDriver.consume_callback(ctx)
      assert DateTime.diff(expires_at, DateTime.utc_now()) > 3500
    end

    # Forgejo rotates refresh tokens, so the refresh token must travel with
    # the access token. A credential holding only the access token can never
    # be refreshed -- it just dies after an hour.
    test "the handed-over credential carries both tokens and the expiry" do
      ctx = context(frame(%{callback_envelope: %{code: "the-code"}}))

      assert {:ok, %{credential_material: {:write_only_handoff, material}}} =
               ForgejoDriver.consume_callback(ctx)

      assert {:ok, decoded} = Jason.decode(material)
      assert decoded["access_token"] == "at-1"
      assert decoded["refresh_token"] == "rt-1"
      assert is_binary(decoded["expires_at"])
    end

    test "accepts a string-keyed callback envelope" do
      ctx = context(frame(%{callback_envelope: %{"code" => "the-code"}}))
      assert {:ok, %{external_account_id: "7"}} = ForgejoDriver.consume_callback(ctx)
    end

    test "a callback without a code is a protocol failure" do
      ctx = context(frame(%{callback_envelope: %{}}))
      assert {:error, :provider_protocol_failed} = ForgejoDriver.consume_callback(ctx)
    end
  end

  describe "consume_callback/1 failures" do
    test "a rejected code does not produce a credential" do
      stub(fn conn -> Plug.Conn.resp(conn, 400, ~s({"error":"invalid_grant"})) end)
      ctx = context(frame(%{callback_envelope: %{code: "bad"}}))

      assert {:error, :provider_protocol_failed} = ForgejoDriver.consume_callback(ctx)
    end

    # The token is real but unusable for our purpose; storing it would leave a
    # connection that looks bound and fails on first use.
    test "a token that cannot identify its account is a protocol failure" do
      stub(fn conn ->
        case conn.request_path do
          "/login/oauth/access_token" ->
            Req.Test.json(conn, %{"access_token" => "at-1", "expires_in" => 3600})

          "/api/v1/user" ->
            Plug.Conn.resp(conn, 403, ~s({"message":"scope"}))
        end
      end)

      ctx = context(frame(%{callback_envelope: %{code: "c"}}))
      assert {:error, :provider_protocol_failed} = ForgejoDriver.consume_callback(ctx)
    end
  end

  describe "reconcile_callback/1" do
    # An authorization code is single-use: once the first attempt consumed it,
    # replaying cannot re-derive the same credential. Reporting "not completed"
    # lets the domain restart authorization instead of inventing a result.
    test "reports not-completed rather than replaying a single-use code" do
      assert {:ok, :not_completed} = ForgejoDriver.reconcile_callback(context(frame()))
    end

    test "reports not-completed even without an exchange closure" do
      assert {:ok, :not_completed} = ForgejoDriver.reconcile_callback(%{})
    end
  end

  # `refresh/1` itself is a two-line delegation to the domain's exchange facade
  # (which owns the scope authority and routes the closure through the credential
  # backend). The provider half -- the part specific to Forgejo -- is `renew/2`,
  # so that is what these exercise: given the current refresh token, call the
  # instance and shape the rotated pair into the result the domain requires.
  describe "renew/2 (the provider half of refresh)" do
    setup do
      stub(fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        form = URI.decode_query(body)

        assert form["grant_type"] == "refresh_token"
        assert form["refresh_token"] == "rt-old"
        assert form["client_id"] == "client-abc"

        Req.Test.json(conn, %{
          "access_token" => "at-new",
          "refresh_token" => "rt-new",
          "expires_in" => 3600
        })
      end)
    end

    test "renews against the current refresh token and returns the rotated pair" do
      assert {:ok, result} =
               ForgejoDriver.renew(context(frame()), %{current_credential: "rt-old"})

      assert {:write_only_handoff, material} = result.replacement_credential
      assert {:ok, decoded} = Jason.decode(material)
      assert decoded["access_token"] == "at-new"
      assert decoded["refresh_token"] == "rt-new"
    end

    test "reports the renewed token's expiry so the connection is not marked eternal" do
      assert {:ok, %{expires_at: %DateTime{} = expires_at}} =
               ForgejoDriver.renew(context(frame()), %{current_credential: "rt-old"})

      assert DateTime.diff(expires_at, DateTime.utc_now()) > 3500
    end

    test "produces exactly the five keys the domain seals" do
      assert {:ok, result} =
               ForgejoDriver.renew(context(frame()), %{current_credential: "rt-old"})

      assert Enum.sort(Map.keys(result)) == [
               :expires_at,
               :granted_permissions_digest,
               :provider_metadata,
               :provider_result_ref,
               :replacement_credential
             ]
    end

    test "an unregistered instance cannot renew" do
      ctx = context(frame(), %{governed_host: "nope.test"})

      assert {:error, :provider_protocol_failed} =
               ForgejoDriver.renew(ctx, %{current_credential: "rt-old"})
    end
  end

  describe "renew/2 failures" do
    test "a rejected refresh token is a protocol failure" do
      stub(fn conn -> Plug.Conn.resp(conn, 400, ~s({"error":"invalid_grant"})) end)

      assert {:error, :provider_protocol_failed} =
               ForgejoDriver.renew(context(frame()), %{current_credential: "rt-old"})
    end
  end

  describe "refresh/1 delegation" do
    test "without a refresh_use it is a protocol failure" do
      assert {:error, :provider_protocol_failed} = ForgejoDriver.refresh(%{})
    end

    test "reconcile_refresh without a refresh_use is a protocol failure" do
      assert {:error, :provider_protocol_failed} = ForgejoDriver.reconcile_refresh(%{})
    end
  end

  describe "discard and revoke" do
    test "discarding a callback result is a no-op" do
      assert :ok = ForgejoDriver.discard_callback_result(%{})
    end

    test "discarding a refresh result is a no-op" do
      assert :ok = ForgejoDriver.discard_refresh_result(%{})
    end

    # Forgejo exposes no token-revocation endpoint (checked against the target
    # instance's swagger): a user revokes access from their account settings.
    # Reporting success for a call that performs nothing would be a lie, but
    # the domain requires a terminal answer -- so it is reported as revoked
    # locally, and the moduledoc says so.
    test "revoke reports the local revocation" do
      assert {:ok, %{revoked: true}} = ForgejoDriver.revoke(%{})
    end
  end
end
