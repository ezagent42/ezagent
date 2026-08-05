defmodule EzagentPluginHello.RegistrationTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Agent.Recipe
  alias Ezagent.Agent.RecipeRegistry
  alias Ezagent.ActionSet.HelloSessionActions
  alias EzagentPluginHello.App
  alias EzagentPluginHello.Application, as: HelloApp

  setup do
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_agent)
    :ok
  end

  test "only the LLM role recipe is platform-materialized" do
    assert HelloApp.roles() == [HelloApp.hello_llm_recipe()]
    refute function_exported?(HelloApp, :hello_front_desk_recipe, 0)
    assert HelloApp.agent_flavors() == []
  end

  test "hello.llm recipe delegates provider and model configuration to the platform" do
    recipe = HelloApp.hello_llm_recipe()
    assert recipe.name == "hello.llm"
    assert recipe.config.credential_optional == true
  end

  test "hello accepts every platform completion flavor" do
    assert App.llm_flavors() == ~w(curl cc-headless cc-headless-custom cc codex codex-remote py)
  end

  test "deterministic Hello operations are Session actions" do
    assert HelloSessionActions.actions() == [
             :route_inbound,
             :rebuild,
             :answer,
             :share,
             :publish,
             :delegate_to_kanban
           ]
  end

  test "role registry contains no retired local-operation recipe" do
    Enum.each(HelloApp.roles(), fn recipe ->
      assert {:ok, _} = RecipeRegistry.seed_role_if_absent(recipe)
    end)

    :ok = RecipeRegistry.flush_cache()

    assert {:ok, %Recipe{name: "hello.llm"}} = RecipeRegistry.lookup("hello.llm")
  end
end
