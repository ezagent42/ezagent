defmodule Ezagent.ProtocolApi.ApiKeyStoreTest do
  @moduledoc """
  P1 test-supplement (security triage) — `Ezagent.ProtocolApi.ApiKeyStore`
  is the authn chokepoint for the LLM Protocol API (`Authorization: Bearer
  pk_<key_id>_<secret>` on `/v1/chat/completions`). It had ZERO tests before
  this PR.

  Pins the key issue/verify lifecycle and, above all, the FAIL-CLOSED
  rejection contract: invalid, revoked, and malformed tokens must never
  verify, and the returned error atom must not leak WHICH precondition
  failed (no existence oracle, no revocation-state oracle) to a caller
  that hasn't proven the secret.

  ## Timing-oracle note (pinned in prose, not asserted — flaky by nature)

  `verify/1` short-circuits at `lookup/1` for an unknown `key_id` — it
  returns `{:error, :invalid_token}` WITHOUT ever calling
  `Bcrypt.verify_pass/2`. A wrong-secret-but-known-key_id request DOES
  call `Bcrypt.verify_pass/2` (deliberately expensive, ~100ms+). This is a
  real timing side-channel: an attacker can distinguish "key_id exists"
  from "key_id doesn't exist" by response latency, enabling key_id
  enumeration (though a bare key_id grants nothing on its own — the
  secret is still required). Per the task's instruction this is PINNED
  behaviorally (both cases return the same `:invalid_token` atom — no
  oracle in the RETURN VALUE) and flagged here/in the PR body rather than
  changed, since fixing it (e.g. always hashing against a dummy value) is
  a product-code change out of scope for a test-only PR.
  """

  use EzagentCore.DataCase, async: true

  alias Ezagent.ProtocolApi.ApiKeyStore
  alias EzagentCore.Repo

  @entity_uri "entity://system/agent/py_default"
  @workspace_uri "workspace://system"

  describe "verify/1 — valid token lifecycle" do
    test "a freshly-issued key verifies and returns entity/workspace/target_agent" do
      {key_id, secret} = issue_key(target_agent: "entity://system/agent/target_x")

      assert {:ok, entity_uri, workspace_uri, target_agent, caps} =
               ApiKeyStore.verify(token(key_id, secret))

      assert URI.to_string(entity_uri) == @entity_uri
      assert URI.to_string(workspace_uri) == @workspace_uri
      assert URI.to_string(target_agent) == "entity://system/agent/target_x"
      # P0 stub (Adapter.cap_subject/0: "API-key auth is external to the
      # cap model") — verify/1 does not yet derive caps from cap_policy.
      # Pin the current contract explicitly so a future change to this is
      # a deliberate, visible diff rather than a silent behavior drift.
      assert caps == MapSet.new()
    end

    test "a key with no target_agent verifies with target_agent: nil" do
      {key_id, secret} = issue_key(target_agent: nil)

      assert {:ok, _entity, _workspace, nil, _caps} = ApiKeyStore.verify(token(key_id, secret))
    end
  end

  describe "verify/1 — fail-closed rejection" do
    test "wrong secret for a real key_id → {:error, :invalid_token}" do
      {key_id, _secret} = issue_key()

      assert {:error, :invalid_token} = ApiKeyStore.verify(token(key_id, "not-the-secret"))
    end

    test "unknown key_id → {:error, :invalid_token} (same atom as wrong secret — no existence oracle)" do
      assert {:error, :invalid_token} =
               ApiKeyStore.verify("pk_never_issued_key_id_anysecret")
    end

    test "revoked key + CORRECT secret → {:error, :revoked}" do
      {key_id, secret} = issue_key(revoked_at: DateTime.utc_now() |> DateTime.truncate(:second))

      assert {:error, :revoked} = ApiKeyStore.verify(token(key_id, secret))
    end

    test "revoked key + WRONG secret → {:error, :invalid_token}, NOT :revoked (no pre-auth revocation leak)" do
      # Ordering invariant: verify_secret/2 runs BEFORE check_not_revoked/1.
      # An attacker who does not hold the correct secret must not be able
      # to learn "this key_id exists AND is revoked" from the response.
      {key_id, _secret} =
        issue_key(revoked_at: DateTime.utc_now() |> DateTime.truncate(:second))

      assert {:error, :invalid_token} = ApiKeyStore.verify(token(key_id, "wrong"))
    end
  end

  describe "verify/1 — malformed token shapes (fail-closed on parse)" do
    test "missing pk_ prefix → invalid_token" do
      assert {:error, :invalid_token} = ApiKeyStore.verify("nope_keyid_secret")
    end

    test "empty string → invalid_token" do
      assert {:error, :invalid_token} = ApiKeyStore.verify("")
    end

    test "bare pk_ prefix with nothing after it → invalid_token" do
      assert {:error, :invalid_token} = ApiKeyStore.verify("pk_")
    end

    test "no underscore separator after key_id → invalid_token" do
      assert {:error, :invalid_token} = ApiKeyStore.verify("pk_keyidwithnosecret")
    end

    test "empty key_id (pk__secret) → invalid_token" do
      assert {:error, :invalid_token} = ApiKeyStore.verify("pk__onlysecret")
    end

    test "empty secret (pk_keyid_) → invalid_token" do
      assert {:error, :invalid_token} = ApiKeyStore.verify("pk_somekeyid_")
    end

    test "secret containing underscores is preserved whole (first-split only)" do
      # parse_token/1 uses :binary.split(rest, "_") — a first-occurrence
      # split, NOT String.split/2 on every "_". A secret that itself
      # contains underscores must round-trip through issue → verify.
      key_id = "us#{System.unique_integer([:positive, :monotonic])}"
      secret = "sec_ret_with_underscores"
      hash = Bcrypt.hash_pwd_salt(secret)

      Repo.insert!(%ApiKeyStore{
        key_id: key_id,
        secret_hash: hash,
        entity_uri: @entity_uri,
        workspace_uri: @workspace_uri,
        label: "underscore-secret",
        allowed_models: [],
        cap_policy: %{}
      })

      assert {:ok, _, _, _, _} = ApiKeyStore.verify("pk_#{key_id}_#{secret}")
      # A wrong guess that truncates at the first underscore must still fail.
      assert {:error, :invalid_token} = ApiKeyStore.verify("pk_#{key_id}_sec")
    end
  end

  describe "list_for_entity/1" do
    test "lists only active (non-revoked) keys for the entity, omitting secret_hash" do
      entity = "entity://system/agent/list_test_#{System.unique_integer([:positive])}"
      {active_id, _} = issue_key(entity_uri: entity, label: "active-one")

      {revoked_id, _} =
        issue_key(
          entity_uri: entity,
          label: "revoked-one",
          revoked_at: DateTime.utc_now() |> DateTime.truncate(:second)
        )

      rows = ApiKeyStore.list_for_entity(entity)
      key_ids = Enum.map(rows, & &1.key_id)

      assert active_id in key_ids
      refute revoked_id in key_ids

      [row] = Enum.filter(rows, &(&1.key_id == active_id))
      # `select: [:key_id, :label, :allowed_models, :inserted_at]` still
      # returns a fixed-shape %ApiKeyStore{} struct (every field key is
      # always present), but Ecto leaves any NON-selected field nil rather
      # than populating it from the row — so `secret_hash` never actually
      # travels over this read path even though the struct "has" the key.
      assert row.secret_hash == nil
    end
  end

  # ----- helpers -------------------------------------------------------

  defp issue_key(opts \\ []) do
    key_id = "ik#{System.unique_integer([:positive, :monotonic])}"
    secret = "s3cr3t#{System.unique_integer([:positive, :monotonic])}"
    hash = Bcrypt.hash_pwd_salt(secret)

    attrs =
      %{
        key_id: key_id,
        secret_hash: hash,
        entity_uri: @entity_uri,
        workspace_uri: @workspace_uri,
        label: "test-key",
        allowed_models: [],
        cap_policy: %{},
        target_agent: nil,
        revoked_at: nil
      }
      |> Map.merge(Map.new(opts))

    Repo.insert!(struct!(ApiKeyStore, attrs))

    {key_id, secret}
  end

  defp token(key_id, secret), do: "pk_#{key_id}_#{secret}"
end
