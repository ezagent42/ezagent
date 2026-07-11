defmodule Ezagent.CapTest do
  use ExUnit.Case, async: true

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

      assert {:ok, artifact} = Cap.issue({:held_by, @issuer}, @target, unstamped_cap())
      assert artifact.granted_by == @issuer
      assert DateTime.compare(artifact.granted_at, before_issue) in [:eq, :gt]
      assert Cap.verify(artifact)
    end

    test "rejects a non-entity issuer" do
      assert {:error, {:granter_not_entity, @non_entity}} =
               Cap.issue({:genesis, @non_entity}, @target, unstamped_cap())
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
