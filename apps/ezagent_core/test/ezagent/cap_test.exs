defmodule Ezagent.CapTest do
  use ExUnit.Case, async: false

  alias Ezagent.{Cap, Capability}

  @issuer Ezagent.URI.new!("entity://team-alpha/user/issuer")
  @target Ezagent.URI.new!("entity://team-alpha/user/grantee")
  @non_entity Ezagent.URI.new!("system://bootstrap")

  defp unstamped_cap do
    %Capability{
      kind: :session,
      behavior: :example,
      action: :send,
      instance: :any,
      workspace_uri: Ezagent.URI.new!("workspace://team-alpha"),
      granted_by: @non_entity,
      granted_at: ~U[2020-01-01 00:00:00Z]
    }
  end

  describe "issue/3" do
    test "produces an artifact whose provenance is the issuer" do
      before_issue = DateTime.utc_now()

      assert {:ok, artifact} = Cap.issue({:genesis, @issuer}, @target, unstamped_cap())
      assert artifact.granted_by == @issuer
      assert DateTime.compare(artifact.granted_at, before_issue) in [:eq, :gt]
      assert Cap.verify(artifact)
    end

    test "rejects a non-entity issuer" do
      assert {:error, {:granter_not_entity, @non_entity}} =
               Cap.issue({:genesis, @non_entity}, @target, unstamped_cap())
    end

    test "rejects an unbounded rule grant before producing an artifact" do
      unbounded = %{unstamped_cap() | kind: :any, behavior: :any, instance: :any}

      assert {:error, :rule_grant_must_be_concrete_scoped} =
               Cap.issue({:rule, :public_view, @issuer}, @target, unbounded)
    end

    test "a manager lacking the delegated cap cannot issue an artifact" do
      previous = Application.get_env(:ezagent_core, Cap)
      loader = EzagentCore.Test.CapAuthorityLoaderStub
      target = Ezagent.URI.new!("entity://team-alpha/agent/managed")
      workspace = Ezagent.URI.new!("workspace://team-alpha")

      manage = Ezagent.CreatorGrant.manage_cap(:agent, target, workspace, @issuer)
      Application.put_env(:ezagent_core, loader, MapSet.new([manage]))
      Application.put_env(:ezagent_core, Cap, authority_loader: loader)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:ezagent_core, Cap, previous),
          else: Application.delete_env(:ezagent_core, Cap)

        Application.delete_env(:ezagent_core, loader)
      end)

      delegated = %Capability{
        kind: :agent,
        behavior: EzagentCore.Test.CapOwnedBehaviorStub,
        action: :read,
        instance: target,
        workspace_uri: workspace,
        granted_by: @non_entity,
        granted_at: ~U[2020-01-01 00:00:00Z]
      }

      assert {:error, :grant_not_delegable} =
               Cap.issue({:held_by, @issuer}, @target, delegated)
    end
  end

  describe "verify/1" do
    test "is total and trusts only entity provenance" do
      assert Cap.verify(%{unstamped_cap() | granted_by: @issuer})
      refute Cap.verify(unstamped_cap())
      refute Cap.verify(:not_an_artifact)
    end
  end
end
