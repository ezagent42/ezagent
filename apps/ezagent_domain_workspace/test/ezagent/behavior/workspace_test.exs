defmodule Ezagent.Behavior.WorkspaceTest do
  use ExUnit.Case, async: true

  alias Ezagent.Behavior.Workspace, as: WB

  describe "init_slice/1" do
    test "defaults to empty MapSet + empty templates + empty rules" do
      slice = WB.init_slice(%{})
      assert MapSet.size(slice.members) == 0
      assert slice.session_templates == %{}
      assert slice.routing_rules == []
    end

    test "accepts members as list and converts to MapSet" do
      slice =
        WB.init_slice(%{
          members: [
            URI.parse("entity://user/system/admin"),
            URI.parse("entity://agent/team-alpha/test_x")
          ]
        })

      assert MapSet.size(slice.members) == 2
    end

    test "accepts members as MapSet directly" do
      uris = MapSet.new([URI.parse("entity://user/system/admin")])
      slice = WB.init_slice(%{members: uris})
      assert slice.members == uris
    end
  end

  describe "member actions" do
    test "list_members returns all member URIs" do
      slice =
        WB.init_slice(%{
          members: [
            URI.parse("entity://user/system/admin"),
            URI.parse("entity://agent/team-alpha/test_x")
          ]
        })

      assert {:ok, ^slice, %{members: members}} = WB.invoke(:list_members, slice, %{}, %{})
      assert length(members) == 2
    end

    test "add_member inserts a new URI" do
      slice = WB.init_slice(%{})
      uri = URI.parse("entity://user/system/admin")

      assert {:ok, new_slice} = WB.invoke(:add_member, slice, %{member: uri}, %{})
      assert MapSet.member?(new_slice.members, uri)
    end

    test "remove_member drops the URI" do
      uri = URI.parse("entity://user/system/admin")
      slice = WB.init_slice(%{members: [uri]})

      assert {:ok, new_slice} = WB.invoke(:remove_member, slice, %{member: uri}, %{})
      assert MapSet.size(new_slice.members) == 0
    end
  end

  describe "session_template actions" do
    test "add_template + list_templates round-trip" do
      slice = WB.init_slice(%{})
      tmpl = %{members: ["entity://user/system/admin"], routing_rules: []}

      {:ok, slice2} = WB.invoke(:add_template, slice, %{name: "main", template: tmpl}, %{})

      assert {:ok, ^slice2, %{templates: %{"main" => ^tmpl}}} =
               WB.invoke(:list_templates, slice2, %{}, %{})
    end

    test "remove_template drops by name" do
      slice = WB.init_slice(%{session_templates: %{"foo" => %{}}})
      {:ok, slice2} = WB.invoke(:remove_template, slice, %{name: "foo"}, %{})
      assert slice2.session_templates == %{}
    end
  end

  describe "routing_rules actions" do
    test "set + list round-trip" do
      slice = WB.init_slice(%{})
      rules = [%{matcher: %{type: "always"}, receivers: ["session://default/system/main"]}]

      {:ok, slice2} = WB.invoke(:set_routing_rules, slice, %{rules: rules}, %{})

      assert {:ok, ^slice2, %{rules: ^rules}} =
               WB.invoke(:list_routing_rules, slice2, %{}, %{})
    end
  end

  describe "instantiate (north-star action)" do
    test "returns child list with one entry per member" do
      uris = [
        URI.parse("entity://user/system/admin"),
        URI.parse("entity://agent/team-alpha/test_cc-builder")
      ]

      slice = WB.init_slice(%{members: uris})

      assert {:ok, ^slice, %{children: children}} =
               WB.invoke(:instantiate, slice, %{}, %{})

      assert length(children) == 2

      assert Enum.all?(children, fn {tag, %URI{}} -> tag == :member end)
    end

    test "empty workspace instantiates to empty child list" do
      slice = WB.init_slice(%{})
      assert {:ok, ^slice, %{children: []}} = WB.invoke(:instantiate, slice, %{}, %{})
    end
  end

  describe "Behavior contract" do
    test "actions/0 lists all 10 actions" do
      # SPEC 2026-05-25-agent-create-cli-gui-parity added `:create_agent`
      # as the 10th action — unified entry for CLI + LV agent creation.
      assert WB.actions() == [
               :list_members,
               :add_member,
               :remove_member,
               :list_templates,
               :add_template,
               :remove_template,
               :list_routing_rules,
               :set_routing_rules,
               :instantiate,
               :create_agent
             ]
    end

    test "state_slice/0 is :workspace" do
      assert WB.state_slice() == :workspace
    end

    test "interface/0 covers every action in actions/0" do
      iface = WB.interface()

      for action <- WB.actions() do
        assert Map.has_key?(iface, action), "interface/0 missing #{action}"
      end
    end
  end
end
