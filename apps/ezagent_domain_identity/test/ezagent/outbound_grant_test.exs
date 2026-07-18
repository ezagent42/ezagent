defmodule Ezagent.OutboundGrantTest do
  use EzagentCore.DataCase, async: false

  import Ezagent.Test.CapHelper, only: [authority_signed_cap_as!: 4]

  alias Ezagent.{Capability, OutboundGrant}

  defp entity_uri(workspace, name) do
    Ezagent.URI.new!("entity://#{workspace}/user/#{name}")
  end

  defp session_uri(workspace, name) do
    Ezagent.URI.new!("session://#{workspace}/default/#{name}")
  end

  defp action_uri(%URI{} = uri), do: %{uri | query: "action=identity.list_caps"}

  defp invalid_principal_type(workspace, name) do
    Ezagent.URI.new!("entity://#{workspace}/banana/#{name}")
  end

  defp issued_attrs(overrides \\ %{}) do
    workspace = Map.get(overrides, :workspace, "team-alpha")
    issuer = Map.get(overrides, :issuer, entity_uri(workspace, "issuer"))
    decision_owner = Map.get(overrides, :decision_owner, entity_uri(workspace, "owner"))
    grantee = Map.get(overrides, :grantee, entity_uri(workspace, "grantee"))
    cap_workspace = Map.get(overrides, :cap_workspace, Ezagent.URI.workspace(workspace))

    proposal =
      Capability.cap(
        :user,
        Ezagent.ActionSet.Identity,
        Map.get(overrides, :action, :list_caps),
        grantee,
        cap_workspace
      )

    {:ok, authority} = Ezagent.Cap.Authority.open(grantee, :user)
    cap = authority_signed_cap_as!(authority, issuer, grantee, proposal)

    %{
      issuer: issuer,
      decision_owner: decision_owner,
      grantee: grantee,
      cap: cap,
      subtype: Map.get(overrides, :subtype, :runtime_mount),
      session_scope: Map.get(overrides, :session_scope, session_uri(workspace, "scope")),
      access: Map.get(overrides, :access, %{"level" => "manage", "paths" => ["board"]})
    }
  end

  describe "record/1 and list APIs" do
    test "stores the complete issued artifact and audit provenance" do
      attrs = issued_attrs()

      assert {:ok, grant} = OutboundGrant.record(attrs)

      assert grant.workspace_uri == "workspace://team-alpha"
      assert grant.issuer_uri == URI.to_string(attrs.issuer)
      assert grant.decision_owner_uri == URI.to_string(attrs.decision_owner)
      assert grant.grantee_uri == URI.to_string(attrs.grantee)
      assert grant.cap == Capability.to_map(attrs.cap)
      assert is_binary(grant.cap_identity)
      assert grant.subtype == :runtime_mount
      assert grant.session_scope_uri == URI.to_string(attrs.session_scope)
      assert grant.access == attrs.access
      assert grant.revoked_at == nil

      assert [^grant] = OutboundGrant.list_by_granter(attrs.issuer)
      assert [^grant] = OutboundGrant.list_by_grantee(attrs.grantee)
    end

    test "cap identity is the canonical five-axis identity including action" do
      attrs = issued_attrs(%{action: :list_caps})
      other_action_attrs = issued_attrs(%{action: :grant_cap})

      assert {:ok, first} = OutboundGrant.record(attrs)
      assert {:ok, second} = OutboundGrant.record(other_action_attrs)

      refute first.cap_identity == second.cap_identity
      assert first.grantee_uri == second.grantee_uri
    end

    test "accepts exactly the closed subtype set" do
      subtypes = [:runtime_mount, :composition, :recipe, :ownership, :structural, :genesis]

      for subtype <- subtypes do
        assert {:ok, %OutboundGrant{subtype: ^subtype}} =
                 OutboundGrant.record(issued_attrs(%{subtype: subtype}))
      end

      assert {:error, {:invalid_subtype, :mount}} =
               OutboundGrant.record(issued_attrs(%{subtype: :mount}))
    end

    test "same full-artifact natural key is idempotent and preserves one row" do
      attrs = issued_attrs()

      assert {:ok, first} = OutboundGrant.record(attrs)
      assert {:ok, retried} = OutboundGrant.record(attrs)

      assert retried.id == first.id
      assert retried.inserted_at == first.inserted_at
      assert Repo.aggregate(OutboundGrant, :count) == 1
    end

    test "lists active and revoked audit history in stable inserted_at/id order" do
      issuer = entity_uri("team-alpha", "history-issuer")
      first_attrs = issued_attrs(%{issuer: issuer, grantee: entity_uri("team-alpha", "a")})
      second_attrs = issued_attrs(%{issuer: issuer, grantee: entity_uri("team-alpha", "b")})

      assert {:ok, first} = OutboundGrant.record(first_attrs)
      assert {:ok, _revoked} = OutboundGrant.revoke(first.id)
      assert {:ok, second} = OutboundGrant.record(second_attrs)

      listed = OutboundGrant.list_by_granter(issuer)
      assert listed == Enum.sort_by(listed, &{&1.inserted_at, &1.id})
      assert Enum.find(listed, &(&1.id == first.id)).revoked_at != nil
      assert Enum.find(listed, &(&1.id == second.id)).revoked_at == nil
    end

    test "granter history may span grantee-owned workspaces without leaking grantee lists" do
      issuer = entity_uri("system", "cross-workspace-issuer")
      alpha_attrs = issued_attrs(%{issuer: issuer, workspace: "team-alpha"})
      beta_attrs = issued_attrs(%{issuer: issuer, workspace: "team-beta"})

      assert {:ok, alpha} = OutboundGrant.record(alpha_attrs)
      assert {:ok, beta} = OutboundGrant.record(beta_attrs)

      assert OutboundGrant.list_by_granter(issuer)
             |> Enum.map(& &1.id)
             |> Enum.sort() == Enum.sort([alpha.id, beta.id])

      assert Enum.map(OutboundGrant.list_by_grantee(alpha_attrs.grantee), & &1.id) == [alpha.id]
      assert Enum.map(OutboundGrant.list_by_grantee(beta_attrs.grantee), & &1.id) == [beta.id]
    end
  end

  describe "revoke/1" do
    test "revokes by id idempotently without changing the first revocation time" do
      attrs = issued_attrs()
      assert {:ok, grant} = OutboundGrant.record(attrs)

      assert {:ok, first_revoke} = OutboundGrant.revoke(grant.id)
      assert first_revoke.revoked_at != nil

      assert {:ok, second_revoke} = OutboundGrant.revoke(grant.id)
      assert second_revoke.revoked_at == first_revoke.revoked_at
    end

    test "revokes by the exact record attrs canonicalizer and stale record retry does not reactivate" do
      attrs = issued_attrs()
      assert {:ok, grant} = OutboundGrant.record(attrs)

      assert {:ok, revoked} = OutboundGrant.revoke(attrs)
      assert revoked.id == grant.id
      assert revoked.revoked_at != nil

      assert {:ok, retried} = OutboundGrant.record(attrs)
      assert retried.id == grant.id
      assert retried.revoked_at == revoked.revoked_at
      assert Repo.aggregate(OutboundGrant, :count) == 1
    end

    test "returns not_found for an unknown id or natural key" do
      attrs = issued_attrs()

      assert {:error, :not_found} = OutboundGrant.revoke(String.duplicate("a", 64))
      assert {:error, :not_found} = OutboundGrant.revoke(attrs)
    end

    test "trusted system-scope id revoke accepts only lowercase SHA256 row ids" do
      assert {:error, :invalid_id} = OutboundGrant.revoke(Ecto.UUID.generate())
      assert {:error, :invalid_id} = OutboundGrant.revoke(String.duplicate("A", 64))
      assert {:error, :invalid_id} = OutboundGrant.revoke(String.duplicate("g", 64))
      assert {:error, :invalid_id} = OutboundGrant.revoke(String.duplicate("a", 63))
    end

    test "natural-key revoke scopes both mutation and reload by grantee workspace" do
      attrs = issued_attrs()
      assert {:ok, grant} = OutboundGrant.record(attrs)

      grant
      |> Ecto.Changeset.change(workspace_uri: "workspace://team-beta")
      |> Repo.update!()

      assert {:error, :not_found} = OutboundGrant.revoke(attrs)
      assert Repo.get!(OutboundGrant, grant.id).revoked_at == nil
    end
  end

  describe "validation and tenant isolation" do
    test "rejects malformed actors, payloads, and access data" do
      attrs = issued_attrs()

      assert {:error, :invalid_issuer} =
               attrs
               |> Map.put(:issuer, session_uri("team-alpha", "not-entity"))
               |> OutboundGrant.record()

      assert {:error, :invalid_decision_owner} =
               attrs
               |> Map.put(:decision_owner, session_uri("team-alpha", "not-owner"))
               |> OutboundGrant.record()

      assert {:error, :invalid_grantee} =
               attrs
               |> Map.put(:grantee, session_uri("team-alpha", "not-grantee"))
               |> OutboundGrant.record()

      assert {:error, :invalid_cap} =
               attrs |> Map.put(:cap, %{kind: :user}) |> OutboundGrant.record()

      assert {:error, :invalid_access} =
               attrs |> Map.put(:access, %{level: "manage"}) |> OutboundGrant.record()
    end

    test "rejects action-bearing issuer, decision owner, and grantee before canonicalization" do
      attrs = issued_attrs()

      for {field, error} <- [
            issuer: :invalid_issuer,
            decision_owner: :invalid_decision_owner,
            grantee: :invalid_grantee
          ] do
        assert {:error, ^error} =
                 attrs
                 |> Map.update!(field, &action_uri/1)
                 |> OutboundGrant.record()
      end
    end

    test "rejects non-principal entity types for every actor" do
      attrs = issued_attrs()

      for {field, error} <- [
            issuer: :invalid_issuer,
            decision_owner: :invalid_decision_owner,
            grantee: :invalid_grantee
          ] do
        assert {:error, ^error} =
                 attrs
                 |> Map.put(field, invalid_principal_type("team-alpha", Atom.to_string(field)))
                 |> OutboundGrant.record()
      end
    end

    test "rejects artifact issuer and grantee mismatches" do
      attrs = issued_attrs()

      assert {:error, :issuer_mismatch} =
               attrs
               |> Map.put(:issuer, entity_uri("team-alpha", "other-issuer"))
               |> OutboundGrant.record()

      assert {:error, :grantee_mismatch} =
               attrs
               |> Map.put(:grantee, entity_uri("team-alpha", "other-grantee"))
               |> OutboundGrant.record()
    end

    test "rejects a concrete cap workspace or session scope outside the grantee workspace" do
      wrong_cap_workspace =
        issued_attrs(%{
          workspace: "team-alpha",
          cap_workspace: Ezagent.URI.workspace("team-beta")
        })

      assert {:error, :cap_workspace_mismatch} = OutboundGrant.record(wrong_cap_workspace)

      assert {:error, :session_scope_workspace_mismatch} =
               issued_attrs()
               |> Map.put(:session_scope, session_uri("team-beta", "other"))
               |> OutboundGrant.record()
    end

    test "does not couple the API to mount, recipe, composition, or socialware consumers" do
      source =
        File.read!(Path.expand("../../lib/ezagent/outbound_grant.ex", __DIR__))

      refute source =~ "SocialwareMount"
      refute source =~ "RecipeCapBinding"
      refute source =~ "CompositionBinding"
      refute source =~ "socialware_mounts"
    end

    test "no runtime consumer calls OutboundGrant before P5 integration" do
      apps_dir = Path.expand("../../..", __DIR__)
      definition = Path.expand("../../lib/ezagent/outbound_grant.ex", __DIR__)

      callers =
        apps_dir
        |> Path.join("*/lib/**/*.ex")
        |> Path.wildcard()
        |> Enum.reject(&(&1 == definition))
        |> Enum.filter(fn path ->
          Regex.match?(
            ~r/\b(?:Ezagent\.)?OutboundGrant\.(?:record|revoke|list_by_granter|list_by_grantee)\s*\(/,
            File.read!(path)
          )
        end)

      assert callers == []
    end
  end
end
