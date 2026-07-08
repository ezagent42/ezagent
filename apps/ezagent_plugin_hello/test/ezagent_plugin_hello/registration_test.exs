defmodule EzagentPluginHello.RegistrationTest do
  @moduledoc """
  hello-as-role acceptance — the `hello.builder` / `hello.concierge` role recipes
  + `roles/0` registration (RF-4), the hello-agents-are-roles gate.

  hello's two agents are ROLES on the unified `Ezagent.Entity.Agent` hosted by the
  `native` flavor (Principle 1 — an agent type is a role × flavor, NEVER its own
  Kind). The old custom Kinds `Ezagent.Entity.HelloBuilder` / `HelloConcierge` are
  DELETED; their `:receive` hooks now load PER-INSTANCE via these recipes (RF-1
  `BehaviorSet.resolve_action` on `Entity.Agent`).

  Unlike `kanban-manager`, the hello agents are NOT `passive`: builder + concierge
  are chat principals (they receive the session's `chat.receive` fan-out and are
  `@`-mentionable / joinable).
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Agent.Recipe
  alias Ezagent.Agent.RecipeRegistry
  alias Ezagent.ActionSet.{HelloBuilder, HelloConcierge, HelloOrchestrator}
  alias EzagentPluginHello.Application, as: HelloApp

  setup do
    # role-as-data: the read-through registry lives in domain_agent (ETS cache +
    # ConfigStore resolution); ensure it is up. DataCase checks out the DB sandbox.
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_agent)
    :ok
  end

  test ":grant_cap lives on IdentityAdmin (the privileged write behavior)" do
    assert :grant_cap in Ezagent.ActionSet.IdentityAdmin.actions()
    refute :grant_cap in Ezagent.ActionSet.Identity.actions()
  end

  test "all four hello role recipes are published in roles/0" do
    assert HelloApp.hello_front_desk_recipe() in HelloApp.roles()
    assert HelloApp.hello_builder_recipe() in HelloApp.roles()
    assert HelloApp.hello_concierge_recipe() in HelloApp.roles()
    assert HelloApp.hello_llm_recipe() in HelloApp.roles()
  end

  test "hello.llm curl recipe carries provider/model + credential_optional in config" do
    recipe = EzagentPluginHello.Application.hello_llm_recipe()
    assert recipe.name == "hello.llm"
    assert recipe.config.provider == "deepseek"
    assert recipe.config.model == "deepseek-chat"
    assert recipe.config.credential_optional == true
  end

  test "hello.orchestrator recipe — behaviors + caps + non-passive (combined gate)" do
    assert {:ok, %Recipe{} = role} = Recipe.new(HelloApp.hello_front_desk_recipe())

    assert role.name == "hello.front-desk"
    assert role.behaviors == [HelloOrchestrator]
    # NOT passive — the orchestrator is the chat front desk (receives the fan-out).
    refute role.passive

    # `:hello_sync_result` — the unique in-process-sync seam `Agent.Receive`
    # re-dispatches chat into (the `"hello"` flavor adapter delivers, this action
    # routes). Unique so it is not shadowed by curl's global `:sync_result`.
    assert [%{behavior: HelloOrchestrator, action: :hello_sync_result} = cap] =
             role.requested_caps

    refute Map.has_key?(cap, :kind)
  end

  test "hello.builder recipe — behaviors + caps + non-passive (combined gate)" do
    assert {:ok, %Recipe{} = role} = Recipe.new(HelloApp.hello_builder_recipe())

    assert role.name == "hello.builder"
    assert :rebuild in HelloBuilder.actions()
    # Behaviors is EXACTLY [Behavior.HelloBuilder] — receive delivery + rebuild dispatch.
    assert role.behaviors == [HelloBuilder]
    # NOT passive — the builder is a chat principal (receives fan-out, @-mentionable).
    refute role.passive

    # requested_caps: atom-keyed cap-template MAP {behavior, action}, no `kind`
    # materialization axis (Recipe.CapMint injects `:agent` per the native flavor).
    assert [
             %{behavior: HelloBuilder, action: :receive} = receive_cap,
             %{behavior: HelloBuilder, action: :rebuild} = rebuild_cap
           ] = role.requested_caps

    refute Map.has_key?(receive_cap, :kind)
    refute Map.has_key?(rebuild_cap, :kind)
  end

  test "hello.concierge recipe — behaviors + caps + non-passive (combined gate)" do
    assert {:ok, %Recipe{} = role} = Recipe.new(HelloApp.hello_concierge_recipe())

    assert role.name == "hello.concierge"
    assert role.behaviors == [HelloConcierge]
    refute role.passive

    assert %{behavior: HelloConcierge, action: :receive} in role.requested_caps
    refute Map.has_key?(cap, :kind)
  end

  test "hello flavor instance_behaviors includes HelloOrchestrator" do
    [decl] = EzagentPluginHello.Application.agent_flavors()
    assert decl.flavor == "hello"
    assert is_function(decl.instance_behaviors, 0)
    assert Ezagent.ActionSet.HelloOrchestrator in decl.instance_behaviors.()
  end

  test "role-as-data — roles/0 → seed_role_if_absent → read-through lookup round-trip" do
    Enum.each(HelloApp.roles(), fn recipe ->
      assert {:ok, _} = RecipeRegistry.seed_role_if_absent(recipe)
    end)

    :ok = RecipeRegistry.flush_cache()

    assert {:ok,
            %Recipe{name: "hello.front-desk", behaviors: [HelloOrchestrator], passive: false}} =
             RecipeRegistry.lookup("hello.front-desk")

    assert {:ok, %Recipe{name: "hello.builder", behaviors: [HelloBuilder], passive: false}} =
             RecipeRegistry.lookup("hello.builder")

    assert {:ok, %Recipe{name: "hello.concierge", behaviors: [HelloConcierge], passive: false}} =
             RecipeRegistry.lookup("hello.concierge")
  end

  test "hello Definition declares the orchestrator/builder/concierge/llm roles + inbound rule" do
    attrs = EzagentPluginHello.App.hello_definition_attrs("hello-demo")
    {:ok, defn} = Ezagent.Socialware.Definition.new(attrs)

    role_names = Enum.map(defn.roles, & &1.role_name) |> Enum.sort()
    assert role_names == ["builder", "concierge", "llm", "front-desk"]
    assert Enum.all?(defn.roles, &(&1.fill == :agent))
    assert Enum.find(defn.roles, &(&1.role_name == "front-desk")).flavor == "hello"

    assert [rule] = defn.routing_rules
    assert (rule[:receivers] || rule["receivers"]) == ["front-desk"]
  end

  test "hello Definition declares the llm curl member" do
    attrs = EzagentPluginHello.App.hello_definition_attrs("hello-demo")
    {:ok, defn} = Ezagent.Socialware.Definition.new(attrs)
    llm = Enum.find(defn.roles, &(&1.role_name == "llm"))
    assert llm.fill == :agent
    assert llm.flavor == "curl"
    assert llm.recipe == "hello.llm"
  end
end
