defmodule EzagentPluginHello.RegistrationTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Agent.Recipe
  alias Ezagent.Agent.RecipeRegistry
  alias Ezagent.ActionSet.{HelloOrchestrator, HelloSessionActions}
  alias EzagentPluginHello.App
  alias EzagentPluginHello.Application, as: HelloApp

  setup do
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_agent)
    :ok
  end

  test "only the front-desk and LLM role recipes are platform-materialized" do
    assert HelloApp.hello_front_desk_recipe() in HelloApp.roles()
    assert HelloApp.hello_llm_recipe() in HelloApp.roles()
    assert length(HelloApp.roles()) == 2
  end

  test "hello.llm recipe delegates provider and model configuration to the platform" do
    recipe = HelloApp.hello_llm_recipe()
    assert recipe.name == "hello.llm"
    assert recipe.config.credential_optional == true
  end

  test "hello accepts every platform completion flavor" do
    assert App.llm_flavors() == ~w(curl cc-headless cc-headless-custom cc codex codex-remote py)
  end

  test "front-desk remains the only chat-facing Hello agent recipe" do
    assert {:ok, %Recipe{} = role} = Recipe.new(HelloApp.hello_front_desk_recipe())
    assert role.name == "hello.front-desk"
    assert role.behaviors == [HelloOrchestrator]
    refute role.passive
  end

  test "deterministic Hello operations are Session actions" do
    assert HelloSessionActions.actions() == [
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

    assert {:ok, %Recipe{name: "hello.front-desk", behaviors: [HelloOrchestrator]}} =
             RecipeRegistry.lookup("hello.front-desk")
  end
end
