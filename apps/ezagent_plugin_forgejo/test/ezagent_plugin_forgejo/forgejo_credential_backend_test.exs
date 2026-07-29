defmodule EzagentPluginForgejo.ForgejoCredentialBackendTest do
  # Not async: the backend owns one named, public ETS table for the node.
  use ExUnit.Case, async: false

  alias EzagentPluginForgejo.ForgejoCredentialBackend, as: Backend

  @pat "forgejo-pat-0123456789abcdef"

  # The backend is a singleton owned by the plugin's supervision tree (it owns
  # one named ETS table for the node), so these tests exercise the running
  # instance rather than starting a second one. Cases stay independent because
  # every `store/1` mints a fresh random credential_ref.
  setup do
    assert is_pid(Process.whereis(Backend)),
           "expected the plugin supervision tree to own #{inspect(Backend)}"

    :ok
  end

  defp store!(token \\ @pat) do
    assert {:ok, %{credential_ref: ref, credential_version: 1}} =
             Backend.store(%{credential_material: {:write_only_handoff, token}})

    ref
  end

  describe "store/1 and lease_for_operation/1" do
    test "a stored credential leases back the original token" do
      ref = store!()

      assert {:ok, %{credential: @pat, credential_ref: ^ref}} =
               Backend.lease_for_operation(%{credential_ref: ref})
    end

    test "two stores yield distinct credential refs" do
      refute store!() == store!()
    end

    # The whole point of the backend. If this regresses, a PAT sits in
    # plaintext in a public ETS table readable by any process on the node.
    test "the token is not recoverable from the stored row" do
      ref = store!()

      stored = :ets.tab2list(:forgejo_credential_tokens) |> :erlang.term_to_binary()

      refute stored =~ @pat
      assert is_binary(ref)
    end
  end

  describe "replace/1" do
    test "replacing with the expected version bumps the version and the leased token" do
      ref = store!()

      assert {:ok, %{credential_ref: ^ref, credential_version: 2}} =
               Backend.replace(%{
                 credential_ref: ref,
                 expected_credential_version: 1,
                 credential_material: {:write_only_handoff, "rotated-pat"}
               })

      assert {:ok, %{credential: "rotated-pat"}} =
               Backend.lease_for_operation(%{credential_ref: ref})
    end

    test "replacing with a stale version is refused and leaves the credential intact" do
      ref = store!()

      assert {:error, :stale_version} =
               Backend.replace(%{
                 credential_ref: ref,
                 expected_credential_version: 7,
                 credential_material: {:write_only_handoff, "should-not-land"}
               })

      assert {:ok, %{credential: @pat}} = Backend.lease_for_operation(%{credential_ref: ref})
    end

    test "replacing an unknown ref is a conflict" do
      assert {:error, :credential_conflict} =
               Backend.replace(%{
                 credential_ref: "no-such-ref",
                 expected_credential_version: 1,
                 credential_material: {:write_only_handoff, "x"}
               })
    end
  end

  describe "status/1 and revoke/1" do
    test "status reports the current version" do
      ref = store!()

      assert {:ok, %{credential_ref: ^ref, credential_version: 1}} =
               Backend.status(%{credential_ref: ref})
    end

    test "status of an unknown ref is a conflict" do
      assert {:error, :credential_conflict} = Backend.status(%{credential_ref: "nope"})
    end

    test "a revoked credential can no longer be leased" do
      ref = store!()
      assert :ok = Backend.revoke(%{credential_ref: ref, idempotency_key: "k1"})

      assert {:error, :credential_conflict} =
               Backend.lease_for_operation(%{credential_ref: ref})
    end

    test "revoking twice with the same key stays successful" do
      ref = store!()
      assert :ok = Backend.revoke(%{credential_ref: ref, idempotency_key: "k1"})
      assert :ok = Backend.revoke(%{credential_ref: ref, idempotency_key: "k1"})
    end
  end

  describe "refresh exchange" do
    # Forgejo PATs do not refresh -- there is no refresh-token flow to drive.
    # These answer unavailable rather than pretending to succeed.
    test "begin_refresh_exchange is unavailable" do
      assert {:error, :backend_unavailable} = Backend.begin_refresh_exchange(%{})
    end

    test "consume_refresh_exchange is unavailable" do
      assert {:error, :backend_unavailable} = Backend.consume_refresh_exchange(%{})
    end
  end
end
