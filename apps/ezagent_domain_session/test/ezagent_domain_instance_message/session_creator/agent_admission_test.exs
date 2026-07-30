defmodule EzagentDomainInstanceMessage.SessionCreator.AgentAdmissionTest do
  use EzagentCore.DataCase, async: false

  import Ezagent.Test.CapHelper, only: [ensure_workspace_kind!: 1]

  alias Ezagent.Agent.RecipeRegistry
  alias Ezagent.ActionSet.Session, as: SessionBehavior
  alias Ezagent.Credential.UserDefaultSource
  alias Ezagent.Entity.Session
  alias EzagentDomainInstanceMessage.SessionCreator.AgentAdmission
  alias EzagentDomainInstanceMessage.SessionCreator.DefinitionAgents

  defmodule ImmediateTemplate do
    @moduledoc false
    @behaviour Ezagent.Kind.Template

    @impl Ezagent.Kind.Template
    def template_name, do: "agent_admission.immediate"

    @impl Ezagent.Kind.Template
    def validate(%{"agent_uri" => agent_uri}) when is_binary(agent_uri), do: :ok
    def validate(_data), do: {:error, :invalid_agent_admission_immediate_template}

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

  defmodule CredentialTemplate do
    @moduledoc false
    @behaviour Ezagent.Kind.Template
    @behaviour Ezagent.Agent.CredentialAdapter

    @namespace "agent-admission-credential"

    @impl Ezagent.Kind.Template
    def template_name, do: "agent_admission.credential"

    @impl Ezagent.Kind.Template
    def config_dir_namespace, do: @namespace

    @impl Ezagent.Agent.CredentialAdapter
    def credential_connection(_opts), do: {:pty, "Connect test LLM"}

    @impl Ezagent.Agent.CredentialAdapter
    def credential_env_var, do: nil

    @impl Ezagent.Agent.CredentialAdapter
    def credential_relpaths, do: [".credentials.json"]

    @impl Ezagent.Agent.CredentialAdapter
    def secret_relpaths, do: [".credentials.json"]

    @impl Ezagent.Agent.CredentialAdapter
    def auth_failure_signals, do: []

    @impl Ezagent.Agent.CredentialAdapter
    def credential_status(_config_dir, _opts) do
      %{status: Process.get({__MODULE__, :credential_status}, :missing)}
    end

    @impl Ezagent.Kind.Template
    def validate(%{"agent_uri" => agent_uri}) when is_binary(agent_uri), do: :ok
    def validate(_data), do: {:error, :invalid_agent_admission_credential_template}

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

    @impl Ezagent.Kind.Template
    def destroy_config_dir(%URI{} = agent_uri, config_dir) when is_binary(config_dir) do
      if Ezagent.Sandbox.ConfigDir.safe_to_destroy?(config_dir, agent_uri, @namespace) do
        case File.rm_rf(config_dir) do
          {:ok, _removed} -> :ok
          {:error, reason, _path} -> {:error, reason}
        end
      else
        {:error, :unsafe_config_dir}
      end
    end
  end

  @workspace_uri Ezagent.URI.workspace(:system)
  @owner_uri Ezagent.Entity.User.admin_uri()

  setup do
    ensure_workspace_kind!(@workspace_uri)
    register_config_dir_type(CredentialTemplate.config_dir_namespace())
    n = System.unique_integer([:positive])
    recipe_name = seed_recipe(n)
    immediate_flavor = register_flavor("immediate", n, ImmediateTemplate)
    credential_flavor = register_flavor("credential", n, CredentialTemplate)
    session_uri = live_session(n)

    declarations = [
      %{
        role_name: "front-desk",
        fill: :agent,
        recipe: recipe_name,
        flavor: immediate_flavor,
        credential_admission: :immediate
      },
      %{
        role_name: "llm",
        fill: :agent,
        recipe: recipe_name,
        flavor: credential_flavor,
        credential_admission: :before_session_join
      }
    ]

    working_copy =
      SessionBehavior.default_template_working_copy()
      |> Map.put(
        :session_template_uri,
        Ezagent.URI.template("system", :session, "hello@revision-#{n}")
      )
      |> Map.put(:member_declarations, declarations)

    assert {:ok, _} = SessionBehavior.system_set_working_copy(session_uri, working_copy)

    on_exit(fn ->
      Process.delete({CredentialTemplate, :credential_status})

      session_uri
      |> Session.session_member_uris()
      |> Enum.reject(&same_uri?(&1, @owner_uri))
      |> Enum.each(&terminate/1)

      AgentAdmission.list(session_uri)
      |> Enum.each(fn admission ->
        case admission.provisional_agent_uri do
          uri when is_binary(uri) -> terminate(Ezagent.URI.new!(uri))
          _ -> :ok
        end
      end)

      terminate(session_uri)
    end)

    %{
      session_uri: session_uri,
      declarations: declarations,
      credential_flavor: credential_flavor
    }
  end

  test "immediate roles join while a gated role is durably deferred", %{
    session_uri: session_uri,
    declarations: declarations,
    credential_flavor: credential_flavor
  } do
    assert {:ok, %{satisfied: ["front-desk"], skipped: [], deferred: ["llm"]}} =
             DefinitionAgents.materialize_definition_agents(
               session_uri,
               @workspace_uri,
               @owner_uri,
               declarations
             )

    members = members_of(session_uri)
    assert %URI{} = SessionBehavior.role_name_to_uri(members, "front-desk")
    assert SessionBehavior.role_name_to_uri(members, "llm") == nil

    assert [
             %{
               status: :pending_auth,
               role_name: "llm",
               flavor: ^credential_flavor,
               connection: {:pty, %{label: "Connect test LLM"}},
               failure_code: nil,
               attempt_id: nil,
               provisional_agent_uri: nil
             }
           ] = AgentAdmission.list(session_uri)
  end

  test "candidate admission is idempotent, validates credentials, retries, and joins", %{
    session_uri: session_uri,
    declarations: declarations,
    credential_flavor: credential_flavor
  } do
    assert {:ok, _summary} =
             DefinitionAgents.materialize_definition_agents(
               session_uri,
               @workspace_uri,
               @owner_uri,
               declarations
             )

    caps = Ezagent.Identity.list_caps_for(@owner_uri)

    assert {:ok, authenticating} =
             AgentAdmission.begin(session_uri, "llm", @owner_uri, caps)

    assert authenticating.status == :authenticating
    assert is_binary(authenticating.attempt_id)
    assert is_binary(authenticating.provisional_agent_uri)

    candidate_uri = Ezagent.URI.new!(authenticating.provisional_agent_uri)
    assert Ezagent.Kind.alive?(candidate_uri)
    assert SessionBehavior.role_name_to_uri(members_of(session_uri), "llm") == nil

    assert {:ok, duplicate} =
             AgentAdmission.begin(session_uri, "llm", @owner_uri, caps)

    assert duplicate.attempt_id == authenticating.attempt_id
    assert duplicate.provisional_agent_uri == authenticating.provisional_agent_uri

    assert {:error, :authentication_failed, failed} =
             AgentAdmission.complete(
               session_uri,
               "llm",
               authenticating.attempt_id,
               {@owner_uri, caps}
             )

    assert failed.status == :failed
    assert failed.failure_code == :authentication_failed
    refute Ezagent.Kind.alive?(candidate_uri)
    assert SessionBehavior.role_name_to_uri(members_of(session_uri), "llm") == nil

    assert {:ok, retrying} = AgentAdmission.begin(session_uri, "llm", @owner_uri, caps)
    refute retrying.attempt_id == authenticating.attempt_id
    refute retrying.provisional_agent_uri == authenticating.provisional_agent_uri

    Process.put({CredentialTemplate, :credential_status}, :authenticated)

    assert {:ok, joined} =
             AgentAdmission.complete(
               session_uri,
               "llm",
               retrying.attempt_id,
               {@owner_uri, Ezagent.Identity.list_caps_for(@owner_uri)}
             )

    retry_uri = Ezagent.URI.new!(retrying.provisional_agent_uri)
    assert joined.status == :joined
    assert SessionBehavior.role_name_to_uri(members_of(session_uri), "llm") == retry_uri
    assert Ezagent.Kind.alive?(retry_uri)

    assert URI.to_string(retry_uri) ==
             Ezagent.Credential.UserDefaultSource.resolve(
               URI.to_string(@owner_uri),
               "system",
               credential_flavor
             )
  end

  test "cancellation and expiry retire only their provisional agent and preserve a prior source",
       %{
         session_uri: session_uri,
         declarations: declarations,
         credential_flavor: credential_flavor
       } do
    assert {:ok, _summary} =
             DefinitionAgents.materialize_definition_agents(
               session_uri,
               @workspace_uri,
               @owner_uri,
               declarations
             )

    caps = Ezagent.Identity.list_caps_for(@owner_uri)
    llm_declaration = Enum.find(declarations, &(&1.role_name == "llm"))
    second_session = live_session("cancel-#{System.unique_integer([:positive])}")
    on_exit(fn -> terminate(second_session) end)
    copy_declarations(second_session, declarations)

    assert {:ok, %{status: :pending_auth}} = AgentAdmission.defer(second_session, llm_declaration)
    assert {:ok, cancelling} = AgentAdmission.begin(second_session, "llm", @owner_uri, caps)
    cancelling_uri = Ezagent.URI.new!(cancelling.provisional_agent_uri)

    third_session = live_session("expire-#{System.unique_integer([:positive])}")
    on_exit(fn -> terminate(third_session) end)
    copy_declarations(third_session, declarations)
    assert {:ok, %{status: :pending_auth}} = AgentAdmission.defer(third_session, llm_declaration)
    assert {:ok, expiring} = AgentAdmission.begin(third_session, "llm", @owner_uri, caps)
    expiring_uri = Ezagent.URI.new!(expiring.provisional_agent_uri)

    assert {:ok, first} = AgentAdmission.begin(session_uri, "llm", @owner_uri, caps)
    write_fake_credential!(Ezagent.URI.new!(first.provisional_agent_uri))
    Process.put({CredentialTemplate, :credential_status}, :authenticated)

    assert {:ok, %{status: :joined}} =
             AgentAdmission.complete(
               session_uri,
               "llm",
               first.attempt_id,
               {@owner_uri, Ezagent.Identity.list_caps_for(@owner_uri)}
             )

    source =
      Ezagent.Credential.UserDefaultSource.resolve(
        URI.to_string(@owner_uri),
        "system",
        credential_flavor
      )

    assert is_binary(source)

    assert {:ok, cancelled} =
             AgentAdmission.cancel(
               second_session,
               "llm",
               cancelling.attempt_id,
               {@owner_uri, Ezagent.Identity.list_caps_for(@owner_uri)}
             )

    assert cancelled.failure_code == :connection_cancelled
    refute Ezagent.Kind.alive?(cancelling_uri)

    assert {:ok, ^cancelled} =
             AgentAdmission.cancel(
               second_session,
               "llm",
               cancelling.attempt_id,
               {@owner_uri, Ezagent.Identity.list_caps_for(@owner_uri)}
             )

    assert UserDefaultSource.resolve(URI.to_string(@owner_uri), "system", credential_flavor) ==
             source

    assert {:ok, expired} = AgentAdmission.expire(third_session, expiring.attempt_id)
    assert expired.failure_code == :connection_timed_out
    assert eventually(fn -> not Ezagent.Kind.alive?(expiring_uri) end)

    assert UserDefaultSource.resolve(URI.to_string(@owner_uri), "system", credential_flavor) ==
             source
  end

  defp seed_recipe(n) do
    name = "agent-admission-recipe-#{n}"
    RecipeRegistry.invalidate(RecipeRegistry.system_workspace_uri(), name)

    {:ok, _recipe} =
      RecipeRegistry.seed_role_if_absent(%{
        name: name,
        requested_caps: [
          %{behavior: Ezagent.ActionSet.Identity, action: :list_caps}
        ]
      })

    name
  end

  defp register_flavor(prefix, n, template_class) do
    flavor = "agent-admission-#{prefix}-#{n}"

    :ok =
      Ezagent.AgentFlavorRegistry.register(%{
        flavor: flavor,
        kind: Ezagent.Entity.Agent,
        template_class: template_class
      })

    flavor
  end

  defp register_config_dir_type(namespace) do
    type = "#{namespace}-agents"

    case Ezagent.Resource.FsResolver.register_type(type, %{
           backend_component: type,
           authority: &Ezagent.Resource.FsResolver.config_dir_authority/2
         }) do
      :ok -> on_exit(fn -> Ezagent.Resource.FsResolver.unregister_type(type) end)
      {:error, {:already_registered, ^type}} -> :ok
    end
  end

  defp live_session(n) do
    session_uri = Ezagent.URI.session("system", "hello", "agent-admission-#{n}")

    {:ok, _pid} =
      Ezagent.Kind.spawn(Session, %{
        uri: session_uri,
        behaviors: Session.behaviors(),
        owner_uri: @owner_uri
      })

    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, @workspace_uri)
    session_uri
  end

  defp copy_declarations(session_uri, declarations) do
    n = System.unique_integer([:positive])

    working_copy =
      SessionBehavior.default_template_working_copy()
      |> Map.put(
        :session_template_uri,
        Ezagent.URI.template("system", :session, "hello@revision-#{n}")
      )
      |> Map.put(:member_declarations, declarations)

    assert {:ok, _} = SessionBehavior.system_set_working_copy(session_uri, working_copy)
  end

  defp terminate(%URI{} = uri) do
    if Ezagent.Kind.alive?(uri), do: Ezagent.Kind.terminate(uri), else: :ok
  end

  defp members_of(session_uri) do
    {:ok, slice} = Ezagent.Kind.read(session_uri, :session, spawn: :never)
    Map.get(slice, :members, %{})
  end

  defp write_fake_credential!(agent_uri) do
    config_dir = Ezagent.Credential.HomeRuntime.agent_config_dir(agent_uri, CredentialTemplate)
    :ok = File.mkdir_p(config_dir)
    :ok = File.write(Path.join(config_dir, ".credentials.json"), ~s({"test":"credential"}))
  end

  defp same_uri?(%URI{} = left, %URI{} = right),
    do: Ezagent.URI.stable_key(left) == Ezagent.URI.stable_key(right)

  defp eventually(fun, attempts \\ 100)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end
end
