defmodule EzagentDomainInstanceMessage.Integration.DefinitionAgentsMaterializeTest do
  @moduledoc """
  T2-1b — `DefinitionAgents.materialize_definition_agents/4` turns a socialware
  `Definition`'s `agents` (`%{recipe, role_name}`) into LIVE session members that
  hold their recipe caps.

  The cc flavor is unregistered in the `domain_session` test env, so
  `spawn_from_template_content` spawns a bare `Entity.Agent` (no real claude
  sidecar) — enough to prove: (1) the agent joins as a member carrying its
  `role_name` facet, (2) `GrantRecipeCaps` lands the recipe's `requested_caps` on
  the per-session agent URI, (3) idempotent re-materialize, (4) role_name
  uniqueness (batch + vs existing member) and (5) fail-closed on unknown recipe.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Agent.RecipeRegistry
  alias Ezagent.ActionSet.Session, as: SessionBehavior
  alias Ezagent.Entity.Session
  alias Ezagent.KindRegistry
  alias EzagentDomainInstanceMessage.SessionCreator.DefinitionAgents

  defmodule StubTemplate do
    @moduledoc false
    @behaviour Ezagent.Kind.Template

    @impl Ezagent.Kind.Template
    def template_name, do: "definition_agents.stub"

    @impl Ezagent.Kind.Template
    def validate(%{"class" => "definition_agents.stub", "agent_uri" => agent_uri, "cwd" => cwd})
        when is_binary(agent_uri) and is_binary(cwd),
        do: :ok

    def validate(_), do: {:error, :invalid_definition_agents_stub_template}

    @impl Ezagent.Kind.Template
    def instantiate(_name, data, _workspace_uri) do
      uri = Ezagent.URI.new!(data["agent_uri"])

      case Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{
             uri: uri,
             behaviors: Ezagent.Entity.Agent.base_behaviors(),
             role: data["role"]
           }) do
        {:ok, _pid} -> {:ok, [uri], %{fresh?: true, config_dir_path: nil}}
        {:error, {:already_started, _pid}} -> {:ok, [uri], %{fresh?: false}}
        {:error, {:already_registered, _}} -> {:ok, [uri], %{fresh?: false}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @workspace_uri URI.new!("workspace://system")
  @owner_uri URI.new!("entity://system/user/admin")

  defp uniq, do: System.unique_integer([:positive])

  defp register_stub_flavor(n) do
    flavor = "definition_agents_stub_#{n}"

    :ok =
      Ezagent.AgentFlavorRegistry.register(%{
        flavor: flavor,
        kind: Ezagent.Entity.Agent,
        template_class: StubTemplate
      })

    flavor
  end

  defp terminate(uri) do
    case KindRegistry.lookup(uri) do
      {:ok, pid} -> if Process.alive?(pid), do: Ezagent.Kind.terminate(uri)
      :error -> :ok
    end
  end

  defp live_session(n) do
    session_uri = Ezagent.URI.session("system", "generic", "t2-agents-#{n}")

    {:ok, _pid} =
      Ezagent.Kind.spawn(Session, %{uri: session_uri, behaviors: Session.behaviors()})

    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, @workspace_uri)
    on_exit(fn -> terminate(session_uri) end)
    session_uri
  end

  # Seed a recipe with requested_caps over behaviors LOADED in domain_session
  # (so GrantRecipeCaps' loaded-check resolves them).
  defp seed_recipe(n) do
    name = "t2-greeter-#{n}"
    RecipeRegistry.invalidate(RecipeRegistry.system_workspace_uri(), name)

    {:ok, _} =
      RecipeRegistry.seed_role_if_absent(%{
        name: name,
        requested_caps: [
          %{behavior: Ezagent.ActionSet.Identity, action: :list_caps}
        ]
      })

    name
  end

  defp live_agent(n, recipe_name) do
    agent_uri = Ezagent.URI.agent("system", "reusable-#{n}")

    {:ok, _pid} =
      Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{
        uri: agent_uri,
        behaviors: Ezagent.Entity.Agent.base_behaviors()
      })

    :ok = Ezagent.WorkspaceRegistry.bind(agent_uri, @workspace_uri)
    :ok = Ezagent.AgentRecipeAttributes.put(agent_uri, recipe_name)
    on_exit(fn -> terminate(agent_uri) end)
    agent_uri
  end

  defp members_of(session_uri) do
    {:ok, pid} = KindRegistry.lookup(session_uri)
    %{state: %{session: %{state: slice}}} = :sys.get_state(pid)
    Map.get(slice, :members, %{})
  end

  test "materializes a declared agent as a member with its role_name + recipe caps" do
    n = uniq()
    session_uri = live_session(n)
    recipe_name = seed_recipe(n)
    role_name = "greeter-#{n}"

    assert :ok =
             DefinitionAgents.materialize_definition_agents(
               session_uri,
               @workspace_uri,
               @owner_uri,
               [%{recipe: recipe_name, role_name: role_name}]
             )

    members = members_of(session_uri)
    planned = SessionBehavior.role_name_to_uri(members, role_name)
    on_exit(fn -> terminate(planned) end)

    # (1) joined as a member carrying the role_name facet
    assert SessionBehavior.role_name_to_uri(members, role_name) == planned
    assert {:ok, _pid} = KindRegistry.lookup(planned)

    # (2) recipe caps landed on the per-session agent URI
    caps = Ezagent.Identity.list_caps_for(planned)

    assert Enum.any?(caps, fn cap ->
             cap.behavior == Ezagent.ActionSet.Identity and cap.action == :list_caps
           end)
  end

  test "materializes a declared non-cc flavor agent with config, readiness, role, grants, and join" do
    n = uniq()
    session_uri = live_session(n)
    recipe_name = seed_recipe(n)
    role_name = "greeter-non-cc-#{n}"
    flavor = register_stub_flavor(n)

    assert :ok =
             DefinitionAgents.materialize_definition_agents(
               session_uri,
               @workspace_uri,
               @owner_uri,
               [%{recipe: recipe_name, role_name: role_name, flavor: flavor}]
             )

    members = members_of(session_uri)
    planned = SessionBehavior.role_name_to_uri(members, role_name)
    on_exit(fn -> terminate(planned) end)

    assert {:ok, _pid} = KindRegistry.lookup(planned)
    assert :ready = Ezagent.ReadyGate.status(planned)
    assert {:ok, ^flavor} = Ezagent.AgentFlavorAttributes.get(planned)

    # P2 (Gate B): the agent-level attribute records BUILD PROVENANCE (the
    # RECIPE name), NOT the session role. Here recipe_name ("#{recipe_name}")
    # and role_name ("#{role_name}") DIVERGE, proving the de-bake — the session
    # role_name lives only on the membership edge (asserted below).
    assert {:ok, ^recipe_name} = Ezagent.AgentRecipeAttributes.fetch(planned)

    assert {:ok, sandbox_slice} = Ezagent.Kind.get_slice(planned, :sandbox)
    sandbox = Ezagent.Kind.normalize_slice_view(sandbox_slice)
    assert Map.has_key?(sandbox, :config_dir_path)

    # the SESSION role_name is on the edge, resolving to the same agent
    assert SessionBehavior.role_name_to_uri(members, role_name) == planned

    caps = Ezagent.Identity.list_caps_for(planned)

    assert Enum.any?(caps, fn cap ->
             cap.behavior == Ezagent.ActionSet.Identity and cap.action == :list_caps
           end)
  end

  test "reuse install choice joins the selected recipe-matching agent through the edge role" do
    n = uniq()
    session_uri = live_session(n)
    recipe_name = seed_recipe(n)
    role_name = "reuse-advisor-#{n}"
    reusable = live_agent(n, recipe_name)

    assert :ok =
             DefinitionAgents.materialize_definition_agents(
               session_uri,
               @workspace_uri,
               @owner_uri,
               [
                 %{
                   recipe: recipe_name,
                   role_name: role_name,
                   install_mode: :reuse,
                   reuse_agent_uri: reusable
                 }
               ]
             )

    members = members_of(session_uri)
    assert SessionBehavior.role_name_to_uri(members, role_name) == reusable
    assert map_size(members) == 1
  end

  test "reuse install choice rejects an agent from a different recipe" do
    n = uniq()
    session_uri = live_session(n)
    recipe_name = seed_recipe(n)
    other_recipe = seed_recipe("other-#{n}")
    role_name = "reuse-mismatch-#{n}"
    reusable = live_agent(n, other_recipe)

    assert {:error, {:reuse_agent_recipe_mismatch, ^role_name, ^reusable}} =
             DefinitionAgents.materialize_definition_agents(
               session_uri,
               @workspace_uri,
               @owner_uri,
               [
                 %{
                   recipe: recipe_name,
                   role_name: role_name,
                   install_mode: :reuse,
                   reuse_agent_uri: reusable
                 }
               ]
             )

    refute Map.has_key?(members_of(session_uri), reusable)
  end

  test "idempotent re-materialize (repair/restart) does not error or double-join" do
    n = uniq()
    session_uri = live_session(n)
    recipe_name = seed_recipe(n)
    role_name = "greeter-#{n}"
    agents = [%{recipe: recipe_name, role_name: role_name}]

    assert :ok =
             DefinitionAgents.materialize_definition_agents(
               session_uri,
               @workspace_uri,
               @owner_uri,
               agents
             )

    members = members_of(session_uri)
    planned = SessionBehavior.role_name_to_uri(members, role_name)
    on_exit(fn -> terminate(planned) end)

    # second call is a no-op skip (member already at our deterministic URI)
    assert :ok =
             DefinitionAgents.materialize_definition_agents(
               session_uri,
               @workspace_uri,
               @owner_uri,
               agents
             )

    assert map_size(
             Enum.filter(members, fn {_uri, m} -> m[:role_name] == role_name end)
             |> Map.new()
           ) == 1
  end

  test "rejects a duplicate role_name within the same agents batch" do
    n = uniq()
    session_uri = live_session(n)
    recipe_name = seed_recipe(n)
    role_name = "dup-#{n}"

    assert {:error, {:duplicate_agent_role_name, ^role_name}} =
             DefinitionAgents.materialize_definition_agents(
               session_uri,
               @workspace_uri,
               @owner_uri,
               [
                 %{recipe: recipe_name, role_name: role_name},
                 %{recipe: recipe_name, role_name: role_name}
               ]
             )
  end

  test "fails closed on an unknown recipe (never a cap-less spawn)" do
    n = uniq()
    session_uri = live_session(n)
    missing = "no-such-recipe-#{n}"

    assert {:error, {:unknown_agent_recipe, ^missing}} =
             DefinitionAgents.materialize_definition_agents(
               session_uri,
               @workspace_uri,
               @owner_uri,
               [%{recipe: missing, role_name: "ghost-#{n}"}]
             )
  end
end
