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

  # These use the shape the domain ACTUALLY sends after a reauthorization
  # (`credential_command/3` -> `prior_credential_ref` + real material). An
  # earlier version of these tests passed `credential_ref`, a key no caller
  # sends -- they were green against a calling convention that does not exist,
  # which is how a `FunctionClauseError` on every real refresh went unnoticed.
  describe "replace/1 (reauthorization shape)" do
    test "replacing with the expected version bumps the version and the leased token" do
      ref = store!()

      assert {:ok, %{credential_ref: ^ref, credential_version: 2}} =
               Backend.replace(%{
                 prior_credential_ref: ref,
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
                 prior_credential_ref: ref,
                 expected_credential_version: 7,
                 credential_material: {:write_only_handoff, "should-not-land"}
               })

      assert {:ok, %{credential: @pat}} = Backend.lease_for_operation(%{credential_ref: ref})
    end

    test "replacing an unknown ref is a conflict" do
      assert {:error, :credential_conflict} =
               Backend.replace(%{
                 prior_credential_ref: "no-such-ref",
                 expected_credential_version: 1,
                 credential_material: {:write_only_handoff, "x"}
               })
    end

    # The refresh shape carries only a handoff reference. One that was never
    # minted must not resolve to anything.
    test "an unknown handoff reference is a conflict" do
      assert {:error, :credential_conflict} =
               Backend.replace(%{
                 credential_material: {:write_only_handoff, "never-minted"},
                 expected_credential_version: 1
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

  # The refresh-exchange callbacks are exercised in
  # `EzagentPluginForgejo.CredentialRefreshTest`. Two tests here previously
  # asserted they answered `:backend_unavailable`; renewal landing turned them
  # red, which is exactly what they were for.
end
