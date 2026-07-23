Code.require_file(Path.expand("../../support/session_assurance_verifier.ex", __DIR__))

defmodule Ezagent.ProviderConnection.SessionAssuranceTest do
  use EzagentCore.DataCase, async: false

  import Ezagent.Test.CapHelper,
    only: [authority_signed_cap!: 3, install_test_authority!: 2]

  alias Ezagent.ActionSet.ProviderConnection

  alias Ezagent.ProviderConnection.{
    Assurance,
    SessionAssuranceVerifier,
    TestSessionAssuranceVerifier
  }

  @actions [:reauthorize, :revoke, :disconnect]

  setup do
    verifier =
      start_supervised!(%{
        id: {Agent, make_ref()},
        start: {TestSessionAssuranceVerifier, :start_link, [[observer: self()]]}
      })

    owner = Ezagent.URI.user(:team_alpha, :assurance_owner)
    caller = Ezagent.URI.user(:team_alpha, :assurance_operator)
    authority = install_test_authority!(owner, :user)

    callback =
      authority_signed_cap!(
        authority,
        owner,
        Ezagent.Capability.cap(
          :user,
          ProviderConnection,
          :consume_callback,
          Ezagent.URI.instance(owner),
          Ezagent.Capability.workspace_of(owner)
        )
      )

    parent = self()

    Application.put_env(:ezagent_domain_provider_connection, :command_boundary, fn action, _, _ ->
      send(parent, {:boundary, action})
      {:ok, :accepted}
    end)

    on_exit(fn ->
      Application.delete_env(:ezagent_domain_provider_connection, :command_boundary)
    end)

    {:ok, verifier: verifier, owner: owner, caller: caller, callback: callback}
  end

  test "closed assurance names the action and trusted-session reauth coordinate", ctx do
    attrs = assurance_attrs(:revoke, ctx)

    assert {:ok,
            %Assurance{
              action: :revoke,
              reauth_ref: "trusted-session-reauth-1",
              reauth_version: 7
            }} = Assurance.new(Map.put(attrs, :signature, "signature"))

    for bad <- [
          Map.delete(attrs, :action),
          Map.put(attrs, :action, :refresh),
          Map.put(attrs, :reauth_ref, ""),
          Map.put(attrs, :reauth_version, -1),
          Map.put(attrs, :attempt_ref, "legacy-name"),
          Map.put(attrs, :attempt_version, 7)
        ] do
      assert {:error, _} = Assurance.new(Map.put(bad, :signature, "signature"))
    end
  end

  test "Inspect redacts the bearer proof reference and signature", ctx do
    reauth_ref = "reauth-ref-secret-sentinel"
    assurance = signed_assurance(:revoke, ctx, reauth_ref)
    rendered = inspect(assurance)

    refute rendered =~ reauth_ref
    refute rendered =~ Base.encode16(assurance.signature)
    refute rendered =~ inspect(assurance.signature)
    assert rendered =~ "action: :revoke"
    assert rendered =~ "connection_id: \"connection-1\""
  end

  test "malformed URI structs are total and fail closed in construction and validation", ctx do
    valid = signed_assurance(:revoke, ctx, "uri-totality-proof")
    attrs = assurance_attrs(:revoke, ctx)

    malformed_uris = [
      {:owner_uri, %URI{scheme: "entity", authority: nil, host: nil, path: nil}},
      {:owner_uri, %URI{scheme: "entity", authority: nil, host: "team_alpha", path: "/user"}},
      {:owner_uri, %{ctx.owner | query: "action=provider_connection.revoke"}},
      {:grantee_uri, %URI{scheme: "entity", authority: nil, host: nil, path: "/user/x"}},
      {:grantee_uri,
       %URI{scheme: "entity", authority: nil, host: "team_alpha", path: "/agent/not-user"}},
      {:grantee_uri, %{ctx.caller | query: "action=provider_connection.revoke"}},
      {:workspace_uri, %URI{scheme: "workspace", authority: nil, host: nil}},
      {:workspace_uri,
       %URI{scheme: "workspace", authority: nil, host: "team_alpha", path: "/extra"}},
      {:workspace_uri,
       %{Ezagent.Capability.workspace_of(ctx.owner) | query: "action=provider_connection.revoke"}}
    ]

    for {field, malformed} <- malformed_uris do
      assert {:error, :invalid_assurance} =
               Assurance.new(attrs |> Map.put(field, malformed) |> Map.put(:signature, "sig"))

      assert {:error, :invalid_assurance} = Assurance.validate(Map.put(valid, field, malformed))
    end
  end

  test "malformed DateTime structs are total at construction validation and handler", ctx do
    valid = signed_assurance(:revoke, ctx, "datetime-totality-proof")
    attrs = assurance_attrs(:revoke, ctx)

    malformed_times = [
      %{DateTime.utc_now() | calendar: Ezagent.ProviderConnection.InvalidCalendar},
      %{DateTime.utc_now() | month: 13},
      %{DateTime.utc_now() | hour: 25},
      %{DateTime.utc_now() | utc_offset: 99_999}
    ]

    for malformed <- malformed_times, field <- [:issued_at, :expires_at] do
      assert {:error, :invalid_assurance} =
               Assurance.new(attrs |> Map.put(field, malformed) |> Map.put(:signature, "sig"))

      forged = Map.put(valid, field, malformed)
      assert {:error, :invalid_assurance} = Assurance.validate(forged)

      assert {:error, _closed_reason} =
               invoke(:revoke, forged, verifier_ctx(ctx))

      refute_received {:session_assurance, _, _, _}
      refute_received {:boundary, _}
    end
  end

  test "assurance cannot cross reauthorize, revoke, and disconnect actions", ctx do
    for action <- @actions, other <- @actions -- [action] do
      assurance = signed_assurance(action, ctx, "action-#{action}-#{other}")

      assert {:error, :invalid_assurance_coordinates} =
               invoke(other, assurance, verifier_ctx(ctx))

      refute_received {:session_assurance, _, _, _}
      refute_received {:boundary, _}
    end
  end

  test "owner workspace grantee connection and version are checked before verifier", ctx do
    valid = signed_assurance(:revoke, ctx, "coordinate-proof")

    invalid = [
      %{valid | owner_uri: Ezagent.URI.user(:team_alpha, :other_owner)},
      %{valid | workspace_uri: Ezagent.URI.workspace(:other_workspace)},
      %{valid | grantee_uri: Ezagent.URI.user(:team_alpha, :other_grantee)},
      %{valid | connection_id: "other-connection"},
      %{valid | connection_version: 8}
    ]

    for assurance <- invalid do
      assert {:error, reason} = invoke(:revoke, assurance, verifier_ctx(ctx))
      assert reason in [:invalid_assurance, :invalid_assurance_coordinates]

      refute_received {:session_assurance, _, _, _}
      refute_received {:boundary, _}
    end
  end

  test "delegated grantee may be cross-workspace but remains exactly bound", ctx do
    delegated = %{ctx | caller: Ezagent.URI.user(:operator_workspace, :delegated_operator)}
    assurance = signed_assurance(:revoke, delegated, "cross-workspace-proof")

    assert {:ok, :accepted} = invoke(:revoke, assurance, verifier_ctx(delegated))
    assert_received {:session_assurance, :revoke, ^assurance, :ok}
    assert_received {:boundary, :revoke}

    assert {:error, :invalid_assurance_coordinates} =
             invoke(:revoke, assurance, verifier_ctx(ctx))

    refute_received {:session_assurance, _, _, _}
    refute_received {:boundary, _}
  end

  test "reauth reference and version plus signature are authenticated by verifier", ctx do
    valid = signed_assurance(:revoke, ctx, "authenticated-proof")

    for assurance <- [
          %{valid | reauth_ref: "other-proof"},
          %{valid | reauth_version: valid.reauth_version + 1},
          %{valid | signature: "forged"}
        ] do
      assert {:error, :assurance_rejected} = invoke(:revoke, assurance, verifier_ctx(ctx))
      assert_received {:session_assurance, :revoke, ^assurance, {:error, :assurance_rejected}}
      refute_received {:boundary, _}
    end
  end

  test "direct verifier rejects tampering of every signed assurance field", ctx do
    valid = signed_assurance(:revoke, ctx, "all-fields-proof")

    tampered = [
      %{valid | action: :disconnect},
      %{valid | owner_uri: Ezagent.URI.user(:team_alpha, :other_owner)},
      %{valid | workspace_uri: Ezagent.URI.workspace(:other_workspace)},
      %{valid | grantee_uri: Ezagent.URI.user(:team_alpha, :other_grantee)},
      %{valid | connection_id: "other-connection"},
      %{valid | connection_version: valid.connection_version + 1},
      %{valid | reauth_ref: "other-proof"},
      %{valid | reauth_version: valid.reauth_version + 1},
      %{valid | status: :invalid},
      %{valid | issued_at: DateTime.add(valid.issued_at, -1, :second)},
      %{valid | expires_at: DateTime.add(valid.expires_at, 1, :second)},
      %{valid | key_id: "other-key"},
      %{valid | signature: "forged"}
    ]

    for assurance <- tampered do
      assert {:error, :assurance_rejected} =
               SessionAssuranceVerifier.verify_and_consume(
                 TestSessionAssuranceVerifier,
                 ctx.verifier,
                 assurance.action,
                 assurance,
                 verification_context(assurance)
               )
    end
  end

  test "direct verifier rejects invocation-context drift", ctx do
    assurance = signed_assurance(:revoke, ctx, "context-drift-proof")
    valid = verification_context(assurance)

    drifted = [
      %{valid | owner_uri: Ezagent.URI.user(:team_alpha, :other_owner)},
      %{valid | workspace_uri: Ezagent.URI.workspace(:other_workspace)},
      %{valid | grantee_uri: Ezagent.URI.user(:team_alpha, :other_grantee)},
      %{valid | connection_id: "other-connection"},
      %{valid | connection_version: valid.connection_version + 1},
      %{valid | verified_at: DateTime.add(assurance.expires_at, 1, :second)}
    ]

    for context <- drifted do
      assert {:error, :assurance_rejected} =
               SessionAssuranceVerifier.verify_and_consume(
                 TestSessionAssuranceVerifier,
                 ctx.verifier,
                 :revoke,
                 assurance,
                 context
               )
    end
  end

  test "future and expired assurances fail before verifier", ctx do
    now = DateTime.utc_now()

    future =
      signed_assurance(:revoke, ctx, "future-proof", %{
        issued_at: DateTime.add(now, 120, :second),
        expires_at: DateTime.add(now, 180, :second)
      })

    expired =
      signed_assurance(:revoke, ctx, "expired-proof", %{
        issued_at: DateTime.add(now, -120, :second),
        expires_at: DateTime.add(now, -60, :second)
      })

    for assurance <- [future, expired] do
      assert {:error, :invalid_assurance_time} = invoke(:revoke, assurance, verifier_ctx(ctx))
      refute_received {:session_assurance, _, _, _}
      refute_received {:boundary, _}
    end
  end

  test "trusted-session proof is atomically consumed once across actions", ctx do
    revoke = signed_assurance(:revoke, ctx, "one-time-proof")
    disconnect = signed_assurance(:disconnect, ctx, "one-time-proof")
    verifier_ctx = verifier_ctx(ctx)

    assert {:ok, :accepted} = invoke(:revoke, revoke, verifier_ctx)
    assert_received {:boundary, :revoke}

    assert {:error, :assurance_replayed} = invoke(:revoke, revoke, verifier_ctx)
    refute_received {:boundary, _}

    assert {:error, :assurance_replayed} = invoke(:disconnect, disconnect, verifier_ctx)
    refute_received {:boundary, _}
  end

  test "key rotation cannot make a consumed reauth coordinate reusable", ctx do
    first = signed_assurance(:revoke, ctx, "rotated-proof", %{key_id: "key-before-rotation"})
    rotated = signed_assurance(:revoke, ctx, "rotated-proof", %{key_id: "key-after-rotation"})
    verifier_ctx = verifier_ctx(ctx)

    assert {:ok, :accepted} = invoke(:revoke, first, verifier_ctx)
    assert_received {:boundary, :revoke}

    assert {:error, :assurance_replayed} = invoke(:revoke, rotated, verifier_ctx)
    refute_received {:boundary, _}
  end

  test "concurrent replay has exactly one verifier consume winner", ctx do
    assurance = signed_assurance(:revoke, ctx, "concurrent-one-time-proof")
    verifier_ctx = verifier_ctx(ctx)

    results =
      1..2
      |> Task.async_stream(
        fn _ -> invoke(:revoke, assurance, verifier_ctx) end,
        max_concurrency: 2,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert Enum.count(results, &(&1 == {:ok, :accepted})) == 1
    assert Enum.count(results, &(&1 == {:error, :assurance_replayed})) == 1
    assert_receive {:boundary, :revoke}
    refute_receive {:boundary, :revoke}, 25
  end

  test "verifier port closes rejection exceptions and unexpected results", ctx do
    assurance = signed_assurance(:revoke, ctx, "closed-result-proof")
    verifier_ctx = verifier_ctx(ctx)

    TestSessionAssuranceVerifier.set_mode(ctx.verifier, :reject)
    assert {:error, :assurance_rejected} = invoke(:revoke, assurance, verifier_ctx)

    for mode <- [:raise, :throw, :exit, :arbitrary_error, :wrong_result] do
      TestSessionAssuranceVerifier.set_mode(ctx.verifier, mode)

      assert {:error, :session_assurance_verifier_misconfigured} =
               result = invoke(:revoke, assurance, verifier_ctx)

      refute inspect(result) =~ "session-assurance-verifier-secret-sentinel"
      refute_received {:boundary, _}
    end

    assert {:error, :invalid_session_assurance_verifier} =
             SessionAssuranceVerifier.verify_and_consume(
               Ezagent.ProviderConnection.MissingVerifier,
               nil,
               :revoke,
               assurance,
               verification_context(assurance)
             )

    assert {:error, :invalid_session_assurance_verifier} =
             SessionAssuranceVerifier.verify_and_consume(
               String,
               nil,
               :revoke,
               assurance,
               verification_context(assurance)
             )

    assert {:error, :invalid_session_assurance_verifier} =
             SessionAssuranceVerifier.verify_and_consume(
               TestSessionAssuranceVerifier,
               ctx.verifier,
               :revoke,
               assurance,
               Map.put(verification_context(assurance), :unsigned_extra, "secret")
             )
  end

  test "all three assurance actions are production fail-closed and runtime config cannot open them",
       ctx do
    Application.put_env(
      :ezagent_domain_provider_connection,
      :session_assurance_verifier,
      TestSessionAssuranceVerifier
    )

    Application.put_env(
      :ezagent_domain_provider_connection,
      :assurance_validator,
      TestSessionAssuranceVerifier
    )

    on_exit(fn ->
      Application.delete_env(:ezagent_domain_provider_connection, :session_assurance_verifier)
      Application.delete_env(:ezagent_domain_provider_connection, :assurance_validator)
    end)

    for action <- @actions do
      assurance = signed_assurance(action, ctx, "production-closed-#{action}")

      assert {:error, :assurance_validation_unavailable} =
               invoke(action, assurance, %{
                 self_uri: ctx.owner,
                 caller: ctx.caller,
                 callback: ctx.callback
               })

      refute_received {:session_assurance, _, _, _}
      refute_received {:boundary, _}
    end
  end

  defp invoke(:reauthorize, assurance, ctx) do
    ProviderConnection.handle_reauthorize(
      %{
        connection_id: "connection-1",
        expected_version: 7,
        requested_execution_identity_class: "connected_user",
        requested_permissions_digest: "permissions",
        redirect_uri_id: "callback",
        correlation_id: "reauthorize-correlation",
        callback_artifact: ctx.callback,
        assurance: assurance
      },
      ctx
    )
  end

  defp invoke(action, assurance, ctx) when action in [:revoke, :disconnect] do
    apply(ProviderConnection, String.to_existing_atom("handle_#{action}"), [
      %{connection_id: "connection-1", expected_version: 7, assurance: assurance},
      ctx
    ])
  end

  defp signed_assurance(action, ctx, reauth_ref, overrides \\ %{}) do
    action
    |> assurance_attrs(ctx)
    |> Map.put(:reauth_ref, reauth_ref)
    |> Map.merge(overrides)
    |> TestSessionAssuranceVerifier.issue!()
  end

  defp assurance_attrs(action, ctx) do
    now = DateTime.utc_now()

    %{
      action: action,
      owner_uri: ctx.owner,
      workspace_uri: Ezagent.Capability.workspace_of(ctx.owner),
      grantee_uri: ctx.caller,
      connection_id: "connection-1",
      connection_version: 7,
      reauth_ref: "trusted-session-reauth-1",
      reauth_version: 7,
      status: :valid,
      issued_at: DateTime.add(now, -1, :second),
      expires_at: DateTime.add(now, 60, :second),
      key_id: "trusted-session-key-1"
    }
  end

  defp verifier_ctx(ctx) do
    %{
      self_uri: ctx.owner,
      caller: ctx.caller,
      test_session_assurance_verifier: {TestSessionAssuranceVerifier, ctx.verifier},
      callback: ctx.callback
    }
  end

  defp verification_context(assurance) do
    %{
      owner_uri: assurance.owner_uri,
      workspace_uri: assurance.workspace_uri,
      grantee_uri: assurance.grantee_uri,
      connection_id: assurance.connection_id,
      connection_version: assurance.connection_version,
      verified_at: DateTime.add(assurance.issued_at, 1, :second)
    }
  end
end
