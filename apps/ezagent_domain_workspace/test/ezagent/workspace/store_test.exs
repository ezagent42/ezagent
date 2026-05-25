defmodule Ezagent.Workspace.StoreTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Workspace.Store

  describe "create/2" do
    test "writes a row with default empties when attrs omitted" do
      name = "store-create-#{System.unique_integer([:positive])}"

      assert {:ok, decoded} = Store.create(name)
      assert decoded.name == name
      assert URI.to_string(decoded.uri) == "workspace://#{name}"
      assert decoded.members == []
      assert decoded.session_templates == %{}
      assert decoded.routing_rules == []
    end

    test "encodes members + templates + rules round-trip" do
      name = "store-rt-#{System.unique_integer([:positive])}"
      members = [URI.parse("entity://user/system/admin"), URI.parse("entity://agent/team-alpha/test_x")]
      tmpls = %{"main" => %{"members" => ["entity://user/system/admin"]}}
      rules = [%{"matcher" => "always", "receivers" => ["session://default/team-alpha/a"]}]

      {:ok, decoded} =
        Store.create(name, %{
          members: members,
          session_templates: tmpls,
          routing_rules: rules
        })

      assert Enum.map(decoded.members, &URI.to_string/1) ==
               Enum.map(members, &URI.to_string/1)

      assert decoded.session_templates == tmpls
      assert decoded.routing_rules == rules
    end

    test "duplicate name returns error from unique constraint" do
      name = "dup-#{System.unique_integer([:positive])}"
      {:ok, _} = Store.create(name)
      assert {:error, _} = Store.create(name)
    end
  end

  describe "update paths" do
    setup do
      name = "upd-#{System.unique_integer([:positive])}"
      {:ok, _} = Store.create(name)
      %{name: name}
    end

    test "update_members replaces the list", %{name: name} do
      new_members = [URI.parse("entity://user/system/admin"), URI.parse("entity://agent/team-alpha/test_new")]
      {:ok, _} = Store.update_members(name, new_members)

      assert %{members: actual} = Store.get_by_name(name)

      assert Enum.map(actual, &URI.to_string/1) ==
               Enum.map(new_members, &URI.to_string/1)
    end

    test "update_templates replaces the map", %{name: name} do
      tmpls = %{"oncall" => %{"members" => ["entity://user/system/admin"]}}
      {:ok, _} = Store.update_templates(name, tmpls)

      assert %{session_templates: ^tmpls} = Store.get_by_name(name)
    end

    test "update_routing_rules replaces the list", %{name: name} do
      rules = [%{"matcher" => "always", "receivers" => ["session://default/team-alpha/x"]}]
      {:ok, _} = Store.update_routing_rules(name, rules)

      assert %{routing_rules: ^rules} = Store.get_by_name(name)
    end
  end

  describe "list_all/0" do
    test "returns every row" do
      n1 = "ls-a-#{System.unique_integer([:positive])}"
      n2 = "ls-b-#{System.unique_integer([:positive])}"

      {:ok, _} = Store.create(n1)
      {:ok, _} = Store.create(n2)

      names = Store.list_all() |> Enum.map(& &1.name)
      assert n1 in names
      assert n2 in names
    end
  end

  describe "delete/1" do
    test "removes the row" do
      name = "del-#{System.unique_integer([:positive])}"
      {:ok, _} = Store.create(name)
      assert :ok = Store.delete(name)
      assert is_nil(Store.get_by_name(name))
    end

    test "delete of non-existent name is a no-op (returns :ok)" do
      assert :ok = Store.delete("never-existed-#{System.unique_integer([:positive])}")
    end
  end
end
