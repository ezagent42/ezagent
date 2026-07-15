defmodule Ezagent.Identity.RecipeCapBindingTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.{Cap, Capability}
  alias Ezagent.Identity.RecipeCapBinding
  alias Ezagent.Identity.RecipeCapBinding.Sweeper

  @admin_uri Ezagent.Entity.User.admin_uri()

  setup do
    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(@admin_uri)
    :ok = Ezagent.ReadyGate.await(@admin_uri, 5_000)
    :ok
  end

  defp agent_uri do
    Ezagent.URI.new!(
      "entity://team-alpha/agent/recipe-binding-#{System.unique_integer([:positive])}"
    )
  end

  defp proposal(agent_uri, action \\ :list_caps) do
    Ezagent.Capability.cap(
      :agent,
      Ezagent.ActionSet.Identity,
      action,
      Ezagent.URI.instance(agent_uri),
      Ezagent.URI.workspace_of(agent_uri)
    )
  end

  describe "issue_and_upsert/4" do
    test "fully issues under admin authority before persisting verified artifacts" do
      agent_uri = agent_uri()

      assert {:ok, %{caps: caps, version: 1, issuer_uri: @admin_uri}} =
               RecipeCapBinding.issue_and_upsert(
                 agent_uri,
                 "support-agent",
                 @admin_uri,
                 [proposal(agent_uri)]
               )

      assert [artifact] = caps
      assert Ezagent.Cap.verify(artifact)
      assert artifact.granted_by == @admin_uri
      assert artifact.kind == :agent
      assert artifact.instance == Ezagent.URI.instance(agent_uri)
      assert artifact.workspace_uri == Ezagent.URI.workspace_of(agent_uri)

      assert %RecipeCapBinding{
               workspace_uri: "workspace://team-alpha",
               recipe_name: "support-agent",
               issuer_uri: "entity://system/user/admin",
               version: 1,
               tombstoned_at: nil
             } = Repo.get(RecipeCapBinding, URI.to_string(agent_uri))

      assert {:ok, %{caps: ^caps, version: 1}} = RecipeCapBinding.fetch(agent_uri)
    end

    test "an unauthorized issue commits no binding (C2)" do
      agent_uri = agent_uri()
      unauthorized = Ezagent.URI.new!("entity://team-alpha/user/no-authority")

      assert {:error, {:issue_failed, 0, _reason}} =
               RecipeCapBinding.issue_and_upsert(
                 agent_uri,
                 "must-not-persist",
                 unauthorized,
                 [proposal(agent_uri)]
               )

      assert Repo.get(RecipeCapBinding, URI.to_string(agent_uri)) == nil
      assert RecipeCapBinding.fetch(agent_uri) == :not_found
    end

    test "writer and reader use the same canonical URI.instance key" do
      agent_uri = agent_uri()
      action_uri = Ezagent.URI.with_action(agent_uri, :identity, :list_caps)

      assert {:ok, %{version: 1}} =
               RecipeCapBinding.issue_and_upsert(
                 action_uri,
                 "canonical-key",
                 @admin_uri,
                 [proposal(agent_uri)]
               )

      canonical = URI.to_string(Ezagent.URI.instance(agent_uri))
      assert %RecipeCapBinding{agent_uri: ^canonical} = Repo.get(RecipeCapBinding, canonical)
      assert {:ok, %{version: 1}} = RecipeCapBinding.fetch(action_uri)
      assert {:ok, %{version: 1}} = RecipeCapBinding.fetch(agent_uri)
    end

    test "same logical retry neither bumps version nor duplicates caps" do
      agent_uri = agent_uri()
      duplicate = proposal(agent_uri)

      assert {:ok, %{caps: first_caps, version: 1}} =
               RecipeCapBinding.issue_and_upsert(
                 agent_uri,
                 "idempotent",
                 @admin_uri,
                 [duplicate, duplicate]
               )

      Process.sleep(2)

      assert {:ok, %{caps: retried_caps, version: 1}} =
               RecipeCapBinding.issue_and_upsert(
                 agent_uri,
                 "idempotent",
                 @admin_uri,
                 [duplicate]
               )

      assert length(first_caps) == 1
      assert retried_caps == first_caps
      assert Repo.aggregate(RecipeCapBinding, :count) == 1
    end

    test "changed content and tombstoned URI reuse advance the monotonic version" do
      agent_uri = agent_uri()

      assert {:ok, %{version: 1}} =
               RecipeCapBinding.issue_and_upsert(
                 agent_uri,
                 "versioned",
                 @admin_uri,
                 [proposal(agent_uri)]
               )

      assert {:ok, %{caps: changed_caps, version: 2}} =
               RecipeCapBinding.issue_and_upsert(
                 agent_uri,
                 "versioned",
                 @admin_uri,
                 [proposal(agent_uri, :has_cap?)]
               )

      assert Enum.any?(changed_caps, &(&1.action == :has_cap?))
      assert :ok = RecipeCapBinding.tombstone_if_version(agent_uri, 2)
      assert RecipeCapBinding.fetch(agent_uri) == :not_found

      assert {:ok, %{version: 3}} =
               RecipeCapBinding.issue_and_upsert(
                 agent_uri,
                 "versioned",
                 @admin_uri,
                 [proposal(agent_uri, :has_cap?)]
               )

      assert %RecipeCapBinding{version: 3, tombstoned_at: nil} =
               Repo.get(RecipeCapBinding, URI.to_string(agent_uri))
    end

    test "a mismatched issued artifact is rejected atomically" do
      agent_uri = agent_uri()
      other_agent = agent_uri()

      assert {:error, {:invalid_artifact, 0, :target_mismatch}} =
               RecipeCapBinding.issue_and_upsert(
                 agent_uri,
                 "wrong-target",
                 @admin_uri,
                 [proposal(other_agent)]
               )

      assert Repo.get(RecipeCapBinding, URI.to_string(agent_uri)) == nil
    end

    test "fetch denies a signed artifact whose grantee is not the bound agent" do
      agent_uri = agent_uri()
      other_grantee = agent_uri()

      assert {:ok, %{version: 1}} =
               RecipeCapBinding.issue_and_upsert(
                 agent_uri,
                 "wrong-grantee",
                 @admin_uri,
                 [proposal(agent_uri)]
               )

      assert {:ok, wrong_grantee_artifact} =
               Cap.issue({:admin, @admin_uri}, other_grantee, proposal(agent_uri))

      binding = Repo.get!(RecipeCapBinding, URI.to_string(agent_uri))
      caps = [wrong_grantee_artifact]

      attrs = %{
        artifacts: %{"caps" => Enum.map(caps, &Capability.to_map/1)},
        content_hash: binding_content_hash(binding, caps)
      }

      binding
      |> Ecto.Changeset.change(attrs)
      |> Repo.update!()

      assert RecipeCapBinding.fetch(agent_uri) == :not_found
    end

    test "refresh_exact re-issues an authoritative unsigned binding under exact CAS" do
      agent_uri = agent_uri()

      assert {:ok, %{caps: [signed], version: 1}} =
               RecipeCapBinding.issue_and_upsert(
                 agent_uri,
                 "legacy-refresh",
                 @admin_uri,
                 [proposal(agent_uri)]
               )

      legacy = %{signed | signature: nil, key_id: nil, grantee_uri: nil}
      binding = Repo.get!(RecipeCapBinding, URI.to_string(agent_uri))

      binding
      |> Ecto.Changeset.change(%{
        artifacts: %{"caps" => [Capability.to_map(legacy)]},
        content_hash: binding_content_hash(binding, [legacy])
      })
      |> Repo.update!()

      assert {:ok, %{caps: [^legacy]}} = RecipeCapBinding.fetch(agent_uri)
      assert Ezagent.Cap.verify_for(legacy, agent_uri)
      refute Ezagent.Cap.signed_and_valid?(legacy, agent_uri)

      assert {:ok, %{replacement: replacement, version: 2}} =
               RecipeCapBinding.refresh_exact(agent_uri, legacy)

      assert Ezagent.Cap.signed_and_valid?(replacement, agent_uri)
      assert {:ok, %{caps: [^replacement], version: 2}} = RecipeCapBinding.fetch(agent_uri)

      assert {:ok, :no_match} = RecipeCapBinding.refresh_exact(agent_uri, legacy)
    end
  end

  describe "failure compensation" do
    test "conditional tombstone makes a binding unreadable and GC removes it" do
      agent_uri = agent_uri()

      assert {:ok, %{version: 1}} =
               RecipeCapBinding.issue_and_upsert(
                 agent_uri,
                 "failed-materialization",
                 @admin_uri,
                 [proposal(agent_uri)]
               )

      assert {:error, :version_mismatch} =
               RecipeCapBinding.tombstone_if_version(agent_uri, 2)

      assert {:ok, %{version: 1}} = RecipeCapBinding.fetch(agent_uri)
      assert :ok = RecipeCapBinding.tombstone_if_version(agent_uri, 1)
      assert RecipeCapBinding.fetch(agent_uri) == :not_found

      future = DateTime.add(DateTime.utc_now(), 2 * 24 * 60 * 60, :second)
      assert {:ok, 1} = Sweeper.sweep(future)

      assert %RecipeCapBinding{
               artifacts: %{"caps" => []},
               content_hash: "gc-pruned",
               gc_pruned_at: %DateTime{}
             } = Repo.get(RecipeCapBinding, URI.to_string(agent_uri))
    end

    test "GC retains the generation ledger and closes stale-token ABA" do
      agent_uri = agent_uri()

      assert {:ok, %{version: 1}} =
               RecipeCapBinding.issue_and_upsert(
                 agent_uri,
                 "aba-safe",
                 @admin_uri,
                 [proposal(agent_uri)]
               )

      assert :ok = RecipeCapBinding.tombstone_if_version(agent_uri, 1)

      future = DateTime.add(DateTime.utc_now(), 2 * 24 * 60 * 60, :second)
      assert {:ok, 1} = Sweeper.sweep(future)

      assert {:ok, %{version: 2}} =
               RecipeCapBinding.issue_and_upsert(
                 agent_uri,
                 "aba-safe",
                 @admin_uri,
                 [proposal(agent_uri)]
               )

      assert {:error, :version_mismatch} =
               RecipeCapBinding.tombstone_if_version(agent_uri, 1)

      assert {:ok, %{version: 2}} = RecipeCapBinding.fetch(agent_uri)
    end
  end

  defp binding_content_hash(binding, caps) do
    logical_content = {
      binding.agent_uri,
      binding.workspace_uri,
      binding.recipe_name,
      binding.issuer_uri,
      Enum.map(caps, &artifact_identity/1)
    }

    :sha256
    |> :crypto.hash(:erlang.term_to_binary(logical_content, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  defp artifact_identity(cap) do
    cap
    |> Capability.to_map()
    |> Map.drop(["granted_at", "signature"])
    |> :erlang.term_to_binary([:deterministic])
  end
end
