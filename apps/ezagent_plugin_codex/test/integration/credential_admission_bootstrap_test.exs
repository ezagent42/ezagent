defmodule Ezagent.PluginCodex.Integration.CredentialAdmissionBootstrapTest do
  @moduledoc false

  use EzagentCore.DataCase, async: false

  import Ezagent.Test.CapHelper, only: [ensure_workspace_kind!: 1]

  alias Ezagent.ActionSet.Session, as: SessionBehavior
  alias Ezagent.Agent.RecipeRegistry
  alias Ezagent.Credential.GrantRow
  alias Ezagent.Entity.Session
  alias Ezagent.KindRegistry
  alias Ezagent.PluginCodex.Template.CodexAgent
  alias EzagentDomainInstanceMessage.SessionCreator.AgentAdmission
  alias EzagentDomainInstanceMessage.SessionCreator.DefinitionAgentLifecycle
  alias EzagentDomainInstanceMessage.SessionCreator.DefinitionAgents

  @workspace_uri URI.new!("workspace://system")
  @owner_uri URI.new!("entity://system/user/admin")

  defp uniq, do: System.unique_integer([:positive])

  setup do
    ensure_workspace_kind!(@workspace_uri)
    :ok
  end

  test "Codex admission starts an isolated secret-free PTY before joining" do
    n = uniq()
    session_uri = Ezagent.URI.session("system", "generic", "codex-admission-#{n}")

    {:ok, _pid} =
      Ezagent.Kind.spawn(Session, %{
        uri: session_uri,
        behaviors: Session.behaviors(),
        owner_uri: @owner_uri
      })

    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, @workspace_uri)
    on_exit(fn -> terminate(session_uri) end)

    recipe_name = "codex-admission-worker-#{n}"
    RecipeRegistry.invalidate(RecipeRegistry.system_workspace_uri(), recipe_name)

    {:ok, _} =
      RecipeRegistry.seed_role_if_absent(%{
        name: recipe_name,
        requested_caps: [
          %{behavior: Ezagent.ActionSet.Identity, action: :list_caps}
        ],
        config: %{project_cwd: System.tmp_dir!()}
      })

    role_name = "codex-admission-role-#{n}"

    declaration = %{
      recipe: recipe_name,
      role_name: role_name,
      flavor: "codex",
      credential_admission: :before_session_join
    }

    working_copy =
      SessionBehavior.default_template_working_copy()
      |> Map.put(
        :session_template_uri,
        Ezagent.URI.template("system", :session, "codex-admission@revision-#{n}")
      )
      |> Map.put(:member_declarations, [declaration])

    assert {:ok, _} = SessionBehavior.system_set_working_copy(session_uri, working_copy)

    assert {:ok, %{deferred: [^role_name]}} =
             DefinitionAgents.materialize_definition_agents(
               session_uri,
               @workspace_uri,
               @owner_uri,
               [declaration]
             )

    caps = Ezagent.Identity.list_caps_for(@owner_uri)

    assert {:ok,
            %{
              status: :authenticating,
              connection: {:pty, %{label: "Connect Codex"}}
            } = admission} = AgentAdmission.begin(session_uri, role_name, @owner_uri, caps)

    agent_uri = Ezagent.URI.new!(admission.provisional_agent_uri)
    config_dir = CodexAgent.agent_config_dir(agent_uri)
    on_exit(fn -> File.rm_rf(config_dir) end)

    assert Ezagent.Kind.alive?(agent_uri)
    assert Ezagent.Domain.Pty.alive?(agent_uri)

    assert SessionBehavior.role_name_to_uri(
             DefinitionAgentLifecycle.read_members(session_uri),
             role_name
           ) == nil

    assert GrantRow.get_for_agent(admission.provisional_agent_uri) == nil
    assert File.exists?(Path.join(config_dir, ".ezagent-config-complete"))
    refute File.exists?(Path.join(config_dir, "auth.json"))

    assert {:error, :authentication_failed, %{status: :failed}} =
             AgentAdmission.complete(
               session_uri,
               role_name,
               admission.attempt_id,
               {@owner_uri, caps}
             )

    assert SessionBehavior.role_name_to_uri(
             DefinitionAgentLifecycle.read_members(session_uri),
             role_name
           ) == nil

    refute Ezagent.Kind.alive?(agent_uri)
  end

  defp terminate(uri) do
    case KindRegistry.lookup(uri) do
      {:ok, pid} -> if Process.alive?(pid), do: Ezagent.Kind.terminate(uri)
      :error -> :ok
    end
  end
end
