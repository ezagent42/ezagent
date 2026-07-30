defmodule EzagentPluginForgejo.ForgejoCredentialBackendTest do
  # Not async: the backend owns one named, public ETS table for the node (the
  # handoff vault — the credentials themselves are durable rows now).
  use ExUnit.Case, async: false

  alias EzagentPluginForgejo.ForgejoCredentialBackend, as: Backend

  @pat "forgejo-pat-0123456789abcdef"
  @ws "workspace://acme"

  # The backend is a singleton owned by the plugin's supervision tree, so these
  # tests exercise the running instance rather than starting a second one. Cases
  # stay independent because every `store/1` mints a fresh random
  # credential_ref, and the sandbox rolls back the rows.
  setup do
    assert is_pid(Process.whereis(Backend)),
           "expected the plugin supervision tree to own #{inspect(Backend)}"

    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
    :ok
  end

  defp store!(token \\ @pat) do
    assert {:ok, %{credential_ref: ref, credential_version: 1}} =
             Backend.store(%{
               workspace_uri: @ws,
               credential_material: {:write_only_handoff, token}
             })

    ref
  end

  describe "store/1 and lease_for_operation/1" do
    test "a stored credential leases back the original token" do
      ref = store!()

      assert {:ok, %{credential: @pat, credential_ref: ^ref}} =
               Backend.lease_for_operation(%{
                 workspace_uri: "workspace://acme",
                 credential_ref: ref
               })
    end

    test "two stores yield distinct credential refs" do
      refute store!() == store!()
    end

    # The whole point of the backend. If this regresses, a PAT sits in
    # plaintext in a public ETS table readable by any process on the node.
    test "the token is not recoverable from the stored row" do
      ref = store!()

      %{ciphertext: ciphertext, nonce: nonce} =
        EzagentCore.Repo.get!(EzagentPluginForgejo.CredentialRecord, ref)

      stored = :erlang.term_to_binary({ciphertext, nonce})

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
                 workspace_uri: @ws,
                 credential_material: {:write_only_handoff, "rotated-pat"}
               })

      assert {:ok, %{credential: "rotated-pat"}} =
               Backend.lease_for_operation(%{
                 workspace_uri: "workspace://acme",
                 credential_ref: ref
               })
    end

    test "replacing with a stale version is refused and leaves the credential intact" do
      ref = store!()

      assert {:error, :stale_version} =
               Backend.replace(%{
                 prior_credential_ref: ref,
                 expected_credential_version: 7,
                 workspace_uri: @ws,
                 credential_material: {:write_only_handoff, "should-not-land"}
               })

      assert {:ok, %{credential: @pat}} =
               Backend.lease_for_operation(%{
                 workspace_uri: "workspace://acme",
                 credential_ref: ref
               })
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
               Backend.lease_for_operation(%{
                 workspace_uri: "workspace://acme",
                 credential_ref: ref
               })
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

  describe "durability" do
    # The defect this change closes. The credential used to live in an ETS table
    # owned by THIS process, so a single crash wiped every user's Forgejo
    # credential on the node — including the refresh token, which made recovery
    # a browser re-authorization per user rather than a renewal. Goes through
    # the backend API, not the record module, because the backend is what the
    # domain calls and what used to lose the data.
    test "a stored credential survives the backend process being killed" do
      ref = store!()
      pid = Process.whereis(Backend)
      assert is_pid(pid), "expected the plugin supervision tree to own #{inspect(Backend)}"

      # A probe in the process-owned ETS table. Its disappearance is what makes
      # the credential's survival meaningful: it proves the kill really does
      # destroy this process's ETS, so the credential surviving is durability
      # rather than the kill having been a no-op.
      :ets.insert(:forgejo_credential_handoffs, {"probe", "parked", "target"})
      assert [{"probe", _, _}] = :ets.lookup(:forgejo_credential_handoffs, "probe")

      Process.exit(pid, :kill)

      # Wait for the supervisor to restart it, so the lease below runs against a
      # process whose ETS table is brand new and empty.
      Process.sleep(100)
      assert is_pid(Process.whereis(Backend))

      assert [] == :ets.lookup(:forgejo_credential_handoffs, "probe"),
             "the kill did not wipe process-owned ETS, so this test proves nothing"

      assert {:ok, %{credential: @pat}} =
               Backend.lease_for_operation(%{
                 workspace_uri: "workspace://acme",
                 credential_ref: ref
               })
    end
  end
end
