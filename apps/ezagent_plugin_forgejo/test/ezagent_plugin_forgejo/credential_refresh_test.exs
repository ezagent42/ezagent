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
  alias EzagentPluginForgejo.ForgejoCredentialBackend, as: Backend

  @credential Jason.encode!(%{
                "access_token" => "at-old",
                "refresh_token" => "rt-old",
                "expires_at" => "2026-07-29T10:00:00Z"
              })

  setup do
    assert is_pid(Process.whereis(Backend))

    {:ok, %{credential_ref: ref}} =
      Backend.store(%{credential_material: {:write_only_handoff, @credential}})

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

  describe "consume_refresh_exchange/1" do
    setup %{ref: ref} do
      {:ok, use} = Backend.begin_refresh_exchange(begin_command(ref))
      {:ok, use: use}
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
