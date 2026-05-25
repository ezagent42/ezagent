defmodule Ezagent.Entity.WorkspaceTest do
  use ExUnit.Case, async: true

  alias Ezagent.Entity.Workspace, as: WK

  describe "Kind contract" do
    test "type_name/0 is :workspace" do
      assert WK.type_name() == :workspace
    end

    test "behaviors/0 lists Ezagent.Behavior.Workspace" do
      assert WK.behaviors() == [Ezagent.Behavior.Workspace]
    end

    test "persistence/0 is :ephemeral in Phase 4b (4c flips to snapshot)" do
      assert WK.persistence() == :ephemeral
    end

    test "uri_from_args/1 reads args[:uri]" do
      uri = URI.parse("workspace://test")
      assert WK.uri_from_args(%{uri: uri}) == uri
    end
  end

  describe "uri_for/1" do
    test "builds workspace://name URI" do
      assert WK.uri_for("default") |> URI.to_string() == "workspace://team-alpha"
    end

    test "preserves hyphenated names" do
      assert WK.uri_for("architect-review") |> URI.to_string() ==
               "workspace://architect-review"
    end
  end
end
