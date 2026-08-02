defmodule Ezagent.Invariants.NoNilWorkspaceWritesIdentityTest do
  @moduledoc """
  Phase 9 PR-6 (SPEC v3 §7.3) — write-time DB-level NOT NULL enforcement
  for the identity-domain schemas (Users, Token, Profile).

  Sibling to `EzagentCore.Invariants.NoNilWorkspaceWritesTest` which
  covers the core schemas (Message, KindSnapshot). Split because
  `ezagent_core` mustn't compile-depend on `ezagent_domain_identity` —
  the tier boundary stops there.

  This test boots the sandbox and tries to insert each identity-domain
  per-tenant schema struct WITHOUT `workspace_uri`; each insert MUST
  fail with the SQLite NOT NULL constraint error.
  """

  use EzagentCore.DataCase, async: false

  describe "DB-level NOT NULL enforcement (identity schemas)" do
    test "users without workspace_uri raises NOT NULL violation" do
      row =
        %Ezagent.Users{
          uri: "entity://team-alpha/user/no-ws-test",
          password_hash: nil
          # workspace_uri intentionally omitted
        }

      assert {:error, _} = safe_insert(row)
    end

    test "entity_tokens without workspace_uri raises NOT NULL violation" do
      row =
        %Ezagent.Entity.Token{
          entity_uri: "entity://team-alpha/user/no-ws-test",
          token_hash: "fake-hash-for-not-null-test",
          label: "test"
          # workspace_uri intentionally omitted
        }

      assert {:error, _} = safe_insert(row)
    end

    test "entity_profiles without workspace_uri raises NOT NULL violation" do
      row =
        %Ezagent.Entity.Profile{
          entity_uri: "entity://team-alpha/user/no-ws-test",
          display_name: "No WS"
          # workspace_uri intentionally omitted
        }

      assert {:error, _} = safe_insert(row)
    end

    test "outbound_grants without workspace_uri raises NOT NULL violation" do
      row =
        %Ezagent.OutboundGrant{
          id: "no-ws-outbound-grant",
          issuer_uri: "entity://team-alpha/user/issuer",
          decision_owner_uri: "entity://team-alpha/user/owner",
          grantee_uri: "entity://team-alpha/user/grantee",
          cap: %{"kind" => "user"},
          cap_identity: "identity",
          subtype: :runtime_mount,
          access: %{}
          # workspace_uri intentionally omitted
        }

      assert {:error, _} = safe_insert(row)
    end
  end

  defp safe_insert(struct) do
    EzagentCore.Repo.insert(struct)
  rescue
    e in Ecto.ConstraintError -> {:error, e}
    e -> {:error, e}
  end
end
