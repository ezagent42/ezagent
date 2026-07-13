defmodule EzagentDomainInstanceMessage.Integration.OrchestratorBindingLifecycleTest do
  @moduledoc """
  P1 I5/I7 gate: a served orchestrator URI always has a current durable binding.

  The create test pins the async-gap ordering. The repair tests pin the writer
  invariant: skip restores an active binding; definitive failure leaves a
  discoverable tombstone; both invalidate a stale warm transport cache row.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Agent.RecipeRegistry
  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.Entity.{Session, SessionTemplate, User}
  alias Ezagent.KindRegistry
  alias Ezagent.Socialware.{Definition, DefinitionRegistry}
  alias EzagentDomainInstanceMessage.SessionCreator

  @workspace_uri URI.parse("workspace://system")
  @workspace "workspace://system"

  setup do
    _ = Ezagent.SpawnRegistry.spawn(User.admin_uri())
    :ok = seed_builtins()
    :ok = ensure_orchestrator_recipe()
    :ok
  end

  test "A: create pre-stores the actual random orchestrator URI before async install" do
    n = uniq()
    flavor = register_missing_credential_flavor(n)
    definition_name = write_orchestrator_definition!(n, flavor)
    template_name = persist_template!(n, definition_name)

    assert {:ok, session_uri, %{}} =
             SessionCreator.create_session("binding-create-#{n}", User.admin_uri(),
               template_name: template_name
             )

    binding = binding!(session_uri)

    assert binding.status == :active
    assert binding.epoch == current_epoch!(session_uri)
    assert %URI{scheme: "entity"} = binding.uri
    assert Ezagent.URI.type?(binding.uri, :agent)
    assert Session.session_member_uris(session_uri) == [User.admin_uri()]
  end

  test "B-skip/C: repair restores the current binding and evicts a stale warm cache row" do
    n = uniq()
    flavor = register_missing_credential_flavor(n)
    definition_name = write_orchestrator_definition!(n, flavor)
    template_name = persist_template!(n, definition_name)
    session_uri = create_session!(n, template_name)

    orchestrator_uri =
      EzagentDomainInstanceMessage.SessionCreator.DefinitionAgents.planned_agent_uri(
        @workspace_uri
      )

    put_binding!(session_uri, active_binding(orchestrator_uri, "epoch-before-skip"))
    register_warm_cache!(session_uri, orchestrator_uri, "epoch-before-skip")

    assert {:ok, ^session_uri, %{}} = SessionCreator.repair_orchestrator(session_uri)

    binding = binding!(session_uri)
    assert binding.status == :active
    assert binding.uri == orchestrator_uri
    assert binding.epoch == current_epoch!(session_uri)
    assert binding.epoch != "epoch-before-skip"
    assert warm_cache_lookup(orchestrator_uri) == :error
  end

  test "B-error: definitive repair failure leaves a same-key loud tombstone" do
    n = uniq()
    flavor = register_failing_flavor(n)
    definition_name = write_orchestrator_definition!(n, flavor)
    template_name = persist_template!(n, definition_name)
    session_uri = create_session!(n, template_name)

    orchestrator_uri =
      EzagentDomainInstanceMessage.SessionCreator.DefinitionAgents.planned_agent_uri(
        @workspace_uri
      )

    put_binding!(session_uri, active_binding(orchestrator_uri, "epoch-before-error"))
    register_warm_cache!(session_uri, orchestrator_uri, "epoch-before-error")

    repair_result = SessionCreator.repair_orchestrator(session_uri)

    assert match?({:error, _reason}, repair_result) or
             match?({:error, _reason, _partial}, repair_result)

    binding = binding!(session_uri)
    assert binding.status == :tombstone
    assert binding.uri == orchestrator_uri
    assert binding.epoch == current_epoch!(session_uri)
    assert binding.reason != nil
    assert warm_cache_lookup(orchestrator_uri) == :error
  end

  defp uniq, do: System.unique_integer([:positive])

  defp create_session!(n, template_name) do
    {:ok, session_uri, %{}} =
      SessionCreator.create_session("binding-repair-#{n}", User.admin_uri(),
        template_name: template_name
      )

    session_uri
  end

  defp register_missing_credential_flavor(n) do
    flavor = "binding_missing_credential_#{n}"

    :ok =
      Ezagent.AgentFlavorRegistry.register(%{
        flavor: flavor,
        kind: Ezagent.Entity.Agent,
        template_class:
          EzagentDomainInstanceMessage.Test.OrchestratorBindingMissingCredentialTemplate
      })

    flavor
  end

  defp register_failing_flavor(n) do
    flavor = "binding_failing_#{n}"

    :ok =
      Ezagent.AgentFlavorRegistry.register(%{
        flavor: flavor,
        kind: Ezagent.Entity.Agent,
        template_class: EzagentDomainInstanceMessage.Test.OrchestratorBindingFailingTemplate
      })

    flavor
  end

  defp write_orchestrator_definition!(n, flavor) do
    name = "orchestrator-binding-#{n}"

    {:ok, definition} =
      Definition.new(%{
        name: name,
        title: "Orchestrator binding #{n}",
        bases: [Ezagent.ActionSet.Session],
        shape: [],
        roles: [
          %{role_name: "orchestrator", fill: :agent, recipe: "orchestrator", flavor: flavor}
        ],
        visibility_policy: %{scope: :private, publish_policy: :auto, web_anon_access: false}
      })

    {:ok, _object} =
      DefinitionRegistry.write_definition(definition,
        workspace_uri: @workspace,
        caller_workspace_uri: @workspace,
        actor_uri: User.admin_uri()
      )

    name
  end

  defp persist_template!(n, definition_name) do
    name = "orchestrator-binding-template-#{n}"

    content = %{
      name: name,
      description: "P1 binding lifecycle fixture",
      default_workspace_uri: @workspace_uri,
      parent_template_uri: nil,
      version_tag: nil,
      created_by: User.admin_uri(),
      created_at: nil,
      prompt_templates: %{},
      legends: %{},
      routing_rules: [],
      installs: [definition_name]
    }

    hash = SessionTemplate.compute_version_hash(content)
    uri = SessionTemplate.build_uri(name, hash, workspace: "system")
    :ok = KindSnapshot.delete(URI.to_string(uri))
    {:ok, persisted_uri} = SessionTemplate.persist_version_as_system(content, "system")

    on_exit(fn ->
      terminate_if_alive(EzagentDomainInstanceMessage.SessionTemplateSupervisor, persisted_uri)
    end)

    name
  end

  defp ensure_orchestrator_recipe do
    case RecipeRegistry.lookup(RecipeRegistry.system_workspace_uri(), "orchestrator") do
      {:ok, _} ->
        :ok

      :error ->
        RecipeRegistry.seed_role_if_absent(%{name: "orchestrator", requested_caps: []})
        |> ok_seed()
    end
  end

  defp ok_seed({:ok, _}), do: :ok
  defp ok_seed({:error, reason}), do: {:error, reason}

  defp seed_builtins do
    case DefinitionRegistry.seed_builtin_definitions() do
      :ok -> :ok
      {:error, {:socialware_definition_seed_collision, _}} -> :ok
    end
  end

  defp active_binding(uri, epoch), do: %{uri: uri, epoch: epoch, status: :active, reason: nil}

  defp put_binding!(session_uri, binding) do
    working_copy =
      session_uri
      |> Session.read_template_working_copy()
      |> Map.put(:orchestrator_uri, binding)
      |> Map.put(:orchestrator_materialization_epoch, binding.epoch)

    {:ok, _} = Ezagent.ActionSet.Session.system_set_working_copy(session_uri, working_copy)
    :ok
  end

  defp binding!(session_uri) do
    session_uri
    |> Session.read_template_working_copy()
    |> Map.fetch!(:orchestrator_uri)
  end

  defp current_epoch!(session_uri) do
    session_uri
    |> Session.read_template_working_copy()
    |> Map.fetch!(:orchestrator_materialization_epoch)
  end

  defp register_warm_cache!(session_uri, orchestrator_uri, epoch) do
    registry = Module.concat([Ezagent, Orchestrator, McpRegistry])

    :ok =
      apply(registry, :register, [
        orchestrator_uri,
        [
          session_uri: session_uri,
          workspace_uri: @workspace_uri,
          owner_uri: User.admin_uri(),
          parent_template_uri: nil,
          binding_epoch: epoch
        ]
      ])
  end

  defp warm_cache_lookup(orchestrator_uri) do
    apply(Module.concat([Ezagent, Orchestrator, McpRegistry]), :lookup, [orchestrator_uri])
  end

  defp terminate_if_alive(supervisor, uri) do
    case KindRegistry.lookup(uri) do
      {:ok, pid} when is_pid(pid) ->
        if Process.alive?(pid), do: DynamicSupervisor.terminate_child(supervisor, pid)

      _ ->
        :ok
    end
  end
end
