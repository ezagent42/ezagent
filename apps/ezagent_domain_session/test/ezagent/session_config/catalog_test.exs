defmodule Ezagent.Session.Config.CatalogTest do
  use ExUnit.Case, async: false

  alias Ezagent.Session.Config.{Catalog, ExtensionRegistry}

  @core_names ~w(
    add_managed_member add_participant update_member_template remove_member
    define_rule_set_rule define_prompt_template define_legend update_template
    save_template_as migrate_session list_templates
  )

  setup do
    ExtensionRegistry.reset_for_test!()

    on_exit(fn ->
      ExtensionRegistry.reset_for_test!()
      ExtensionRegistry.assemble!(ExtensionRegistry.discover_loaded_extensions())
    end)

    :ok
  end

  test "the domain owns the exact 11-operation core catalog" do
    assert Enum.map(Catalog.core_operations(), & &1.name) == @core_names
    refute Enum.any?(Catalog.core_operations(), &String.starts_with?(&1.name, "kb_"))

    assert Enum.map(Catalog.schemas(), & &1["name"]) == @core_names
    assert Enum.all?(Catalog.schemas(), &is_map(&1["inputSchema"]))

    declarations =
      Map.new(Catalog.core_operations(), &{&1.name, {&1.target_scope, &1.admission_gate}})

    assert declarations["list_templates"] == {:workspace, :workspace_caps}
    assert declarations["save_template_as"] == {:session, :template_write}
    assert declarations["update_template"] == {:session, :template_write}
    assert declarations["migrate_session"] == {:session, :session_membership}

    assert Enum.all?(
             ~w(add_managed_member add_participant update_member_template remove_member
                define_rule_set_rule define_prompt_template define_legend migrate_session),
             &(declarations[&1] == {:session, :session_membership})
           )
  end

  test "extension assembly is deterministic and rejects duplicate or late names" do
    alpha = %{name: "z_plugin", description: "z", input_schema: object_schema(), route: :z}
    beta = %{name: "a_plugin", description: "a", input_schema: object_schema(), route: :a}

    assert :ok = ExtensionRegistry.assemble!([alpha, beta])
    assert Enum.map(Catalog.operations(), & &1.name) == @core_names ++ ~w(a_plugin z_plugin)

    assert_raise ArgumentError, ~r/already frozen/, fn ->
      ExtensionRegistry.assemble!([])
    end

    ExtensionRegistry.reset_for_test!()

    assert_raise ArgumentError, ~r/duplicate operation/, fn ->
      ExtensionRegistry.assemble!([Map.put(alpha, :name, "list_templates")])
    end

    ExtensionRegistry.reset_for_test!()

    assert_raise ArgumentError, ~r/duplicate operation/, fn ->
      ExtensionRegistry.assemble!([alpha, Map.put(beta, :name, "z_plugin")])
    end
  end

  test "assembled extension names stay wire strings and never require pre-existing atoms" do
    name = "runtime_extension_#{System.unique_integer([:positive])}"

    assert :ok =
             ExtensionRegistry.assemble!([
               %{
                 name: name,
                 description: "runtime",
                 input_schema: object_schema(),
                 route: :runtime
               }
             ])

    assert Ezagent.Session.SessionManager.tool_names() == @core_names ++ [name]
  end

  defp object_schema, do: %{"type" => "object", "properties" => %{}, "required" => []}
end
