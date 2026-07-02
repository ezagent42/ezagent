defmodule Ezagent.Capability.ParserTest do
  use ExUnit.Case, async: true

  alias Ezagent.Capability.Parser

  @granter Ezagent.URI.new!("entity://system/user/admin")
  @now ~U[2026-05-16 00:00:00.000000Z]

  describe "parse/3" do
    test "empty string returns empty list" do
      assert {:ok, []} = Parser.parse("", @granter, @now)
    end

    test "single kind.behavior spec" do
      {:ok, [cap]} = Parser.parse("workspace.workspace", @granter, @now)
      assert cap.kind == :workspace
      assert cap.behavior == Ezagent.ActionSet.Workspace
      assert cap.instance == :any
      assert cap.granted_by == @granter
    end

    test "comma-separated specs" do
      {:ok, caps} = Parser.parse("workspace.workspace,user.identity", @granter, @now)
      assert length(caps) == 2
    end

    test "asterisk → triple-:any cap" do
      {:ok, [cap]} = Parser.parse("*", @granter, @now)
      assert cap.kind == :any
      assert cap.behavior == :any
      assert cap.instance == :any
    end

    test "instance-scoped spec" do
      {:ok, [cap]} =
        Parser.parse("workspace.workspace@workspace://main", @granter, @now)

      assert %URI{scheme: "workspace", host: "main"} = cap.instance
    end

    test "rejects unknown kind atom" do
      assert {:error, {:unknown_kind, _}} =
               Parser.parse(
                 "never-known-#{System.unique_integer([:positive])}.something",
                 @granter,
                 @now
               )
    end

    test "rejects malformed spec (no dot)" do
      assert {:error, {:bad_cap_spec, _}} = Parser.parse("nodothere", @granter, @now)
    end

    test "behavior name not loaded falls back to :any (deferred check)" do
      # Use a kind atom that exists but a behavior name that doesn't
      # resolve to a loaded module.
      {:ok, [cap]} =
        Parser.parse(
          "workspace.never_known_behavior_#{System.unique_integer([:positive])}",
          @granter,
          @now
        )

      assert cap.kind == :workspace
      assert cap.behavior == :any
    end
  end
end
