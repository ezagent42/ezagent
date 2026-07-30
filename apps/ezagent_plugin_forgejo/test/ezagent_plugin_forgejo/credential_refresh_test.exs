defmodule EzagentPluginForgejo.CredentialRefreshTest do
  @moduledoc """
  The credential-custody half of renewal.

  Forgejo access tokens expire in an hour and repository access comes from that
  token — unlike GitHub, whose repo access is minted per operation from an
  installation, making its stored token identity-only. So renewal is
  load-bearing here, and these tests exercise the backend's side of the
  domain's refresh-exchange protocol.
  """
  use ExUnit.Case, async: false

  alias Ezagent.ProviderConnection.CredentialBackend.RefreshUse
  alias Ezagent.ProviderConnection.CredentialRefreshExchange.ScopeAuthority
  alias EzagentPluginForgejo.ForgejoCredentialBackend, as: Backend

  @credential Jason.encode!(%{
                "access_token" => "at-old",
                "refresh_token" => "rt-old",
                "expires_at" => "2026-07-29T10:00:00Z"
              })

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
    assert is_pid(Process.whereis(Backend))

    {:ok, %{credential_ref: ref}} =
      Backend.store(%{
        workspace_uri: "workspace://acme",
        credential_material: {:write_only_handoff, @credential}
      })

    {:ok, ref: ref}
  end

  # Mirrors the command `CredentialRefreshExchange.invoke/3` builds, plus the
  # scope fields it merges in before calling the backend.
  defp begin_command(ref, overrides \\ %{}) do
    Map.merge(
      %{
        current_credential_ref: ref,
        scope_authority: self(),
        scope_token: make_ref(),
        scope_binding_digest: :crypto.hash(:sha256, "binding"),
        credential_backend: Backend,
        function: :refresh,
        workspace_uri: "workspace://acme",
        governed_host: "code.hyprial.test"
      },
      overrides
    )
  end

  describe "begin_refresh_exchange/1" do
    test "returns a RefreshUse carrying the domain's scope identity", %{ref: ref} do
      command = begin_command(ref)

      assert {:ok, %RefreshUse{} = use} = Backend.begin_refresh_exchange(command)

      # The domain re-checks these four in `validate_use/5`; a RefreshUse built
      # with anything else is rejected before the driver ever runs.
      assert RefreshUse.authority(use) == command.scope_authority
      assert RefreshUse.token(use) == command.scope_token
      assert RefreshUse.binding_digest(use) == command.scope_binding_digest
      assert RefreshUse.backend(use) == Backend
    end

    test "an unknown credential ref cannot begin an exchange" do
      assert {:error, :credential_conflict} =
               Backend.begin_refresh_exchange(begin_command("no-such-ref"))
    end

    # The struct is opaque and redacted, but its `private` field is chosen by
    # this backend -- so the guard that matters is that inspecting it cannot
    # surface the tokens.
    test "the RefreshUse does not render the credential", %{ref: ref} do
      {:ok, use} = Backend.begin_refresh_exchange(begin_command(ref))

      refute inspect(use) =~ "rt-old"
      refute inspect(use) =~ "at-old"
    end
  end

  # The domain starts a ScopeAuthority, has the backend build a RefreshUse
  # against it, then CLAIMS it and passes the claimed value on
  # (`credential_refresh_exchange.ex:97-110`). Reproducing that here is what
  # makes these tests exercise the real custody path -- passing the unclaimed
  # value, as an earlier version did, meant the backend's claim check was
  # never executed by any test.
  defp claimed_use(ref) do
    digest = :crypto.hash(:sha256, "binding")
    {:ok, authority} = ScopeAuthority.start(self(), digest)
    {:ok, token} = ScopeAuthority.open(authority)

    {:ok, use} =
      Backend.begin_refresh_exchange(
        begin_command(ref, %{
          scope_authority: authority,
          scope_token: token,
          scope_binding_digest: digest
        })
      )

    {:ok, proof} = ScopeAuthority.claim(authority, token, digest)
    RefreshUse.claimed(use, proof)
  end

  describe "consume_refresh_exchange/1" do
    setup %{ref: ref} do
      {:ok, use: claimed_use(ref)}
    end

    # The claim is what binds a decryption to ONE invocation. An unclaimed
    # RefreshUse reaching the backend means something bypassed the domain
    # facade; handing it the refresh token anyway would defeat the custody
    # boundary the scope authority exists to enforce.
    test "an unclaimed RefreshUse is refused", %{ref: ref} do
      {:ok, unclaimed} = Backend.begin_refresh_exchange(begin_command(ref))

      assert {:error, :correlation_conflict} =
               Backend.consume_refresh_exchange(%{
                 refresh_use: unclaimed,
                 provider_exchange: fn _frame -> {:ok, :not_completed} end
               })
    end

    # The whole point: the driver needs the REFRESH token to call the provider.
    # Handing it the access token (the obvious slip) would make every renewal
    # fail with invalid_grant.
    test "hands the driver the refresh token, not the access token", %{use: use} do
      test_pid = self()

      Backend.consume_refresh_exchange(%{
        refresh_use: use,
        provider_exchange: fn frame ->
          send(test_pid, {:frame, frame})
          {:ok, :not_completed}
        end
      })

      assert_received {:frame, %{current_credential: current}}
      assert current == "rt-old"
    end

    test "seals a provider result into the domain's expected shape", %{use: use} do
      expires_at = DateTime.utc_now() |> DateTime.add(3600, :second)

      result =
        Backend.consume_refresh_exchange(%{
          refresh_use: use,
          provider_exchange: fn _frame ->
            {:ok,
             %{
               provider_result_ref: "forgejo-refresh-1",
               replacement_credential: {:write_only_handoff, "new-material"},
               granted_permissions_digest: "requested:write:repository",
               expires_at: expires_at,
               provider_metadata: %{}
             }}
          end
        })

      assert {:ok, sealed} = result

      # `validate_result/2` requires exactly these keys, with
      # `credential_material` replacing `replacement_credential`.
      assert Map.keys(sealed) |> Enum.sort() ==
               [
                 :credential_material,
                 :expires_at,
                 :granted_permissions_digest,
                 :provider_metadata,
                 :provider_result_ref
               ]

      assert {:write_only_handoff, handoff} = sealed.credential_material
      assert is_binary(handoff) and handoff != ""
      assert sealed.expires_at == expires_at
    end

    test "passes through a not-completed reconciliation", %{use: use} do
      assert {:ok, :not_completed} =
               Backend.consume_refresh_exchange(%{
                 refresh_use: use,
                 provider_exchange: fn _frame -> {:ok, :not_completed} end
               })
    end

    test "a provider failure is propagated, not swallowed", %{use: use} do
      assert {:error, :provider_protocol_failed} =
               Backend.consume_refresh_exchange(%{
                 refresh_use: use,
                 provider_exchange: fn _frame -> {:error, :provider_protocol_failed} end
               })
    end

    # A malformed provider result must not be sealed and handed on: the domain
    # would reject it anyway, but failing here keeps the bad shape from being
    # recorded as this backend's sealed result.
    test "a result missing required keys is refused", %{use: use} do
      assert {:error, :provider_protocol_failed} =
               Backend.consume_refresh_exchange(%{
                 refresh_use: use,
                 provider_exchange: fn _frame -> {:ok, %{provider_result_ref: "only-this"}} end
               })
    end

    # The defect this closes: an earlier version minted a handoff REFERENCE
    # without parking anything behind it, so the domain's follow-up
    # `replace/1` -- which carries only that reference -- had nothing to
    # resolve. Testing seal and replace separately kept both halves green
    # while the join between them was broken. This walks the whole path.
    test "the rotated credential survives the handoff into replace/1", %{ref: ref, use: use} do
      rotated = Jason.encode!(%{"access_token" => "at-new", "refresh_token" => "rt-new"})

      assert {:ok, sealed} =
               Backend.consume_refresh_exchange(%{
                 refresh_use: use,
                 provider_exchange: fn _frame ->
                   {:ok,
                    %{
                      provider_result_ref: "forgejo-refresh-1",
                      replacement_credential: {:write_only_handoff, rotated},
                      granted_permissions_digest: "requested:write:repository",
                      expires_at: DateTime.utc_now(),
                      provider_metadata: %{}
                    }}
                 end
               })

      # Exactly the command `refresh.ex:449` sends: the handoff reference and
      # a version, with NO credential_ref.
      assert {:ok, %{credential_ref: ^ref, credential_version: 2}} =
               Backend.replace(%{
                 credential_material: sealed.credential_material,
                 expected_credential_version: 1
               })

      assert {:ok, %{credential: leased}} = Backend.lease_for_operation(%{credential_ref: ref})

      assert {:ok, %{"access_token" => "at-new", "refresh_token" => "rt-new"}} =
               Jason.decode(leased)
    end

    # One-use: a replayed replace must not re-apply a rotation.
    test "a handoff cannot be redeemed twice", %{use: use} do
      {:ok, sealed} =
        Backend.consume_refresh_exchange(%{
          refresh_use: use,
          provider_exchange: fn _frame ->
            {:ok,
             %{
               provider_result_ref: "forgejo-refresh-2",
               replacement_credential: {:write_only_handoff, "{}"},
               granted_permissions_digest: "d",
               expires_at: nil,
               provider_metadata: %{}
             }}
          end
        })

      command = %{credential_material: sealed.credential_material, expected_credential_version: 1}

      assert {:ok, _} = Backend.replace(command)
      assert {:error, :credential_conflict} = Backend.replace(command)
    end

    test "a RefreshUse belonging to another backend is refused", %{ref: ref} do
      command = begin_command(ref)

      foreign =
        RefreshUse.new(
          command.scope_authority,
          command.scope_token,
          command.scope_binding_digest,
          SomeOtherBackend,
          %{}
        )

      assert {:error, :correlation_conflict} =
               Backend.consume_refresh_exchange(%{
                 refresh_use: foreign,
                 provider_exchange: fn _frame -> {:ok, :not_completed} end
               })
    end
  end
end
