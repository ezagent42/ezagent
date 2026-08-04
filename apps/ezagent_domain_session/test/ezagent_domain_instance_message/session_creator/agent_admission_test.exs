defmodule EzagentDomainInstanceMessage.SessionCreator.AgentAdmissionTest do
  use EzagentCore.DataCase, async: false

  import Ezagent.Test.CapHelper, only: [ensure_workspace_kind!: 1]

  alias Ezagent.Agent.RecipeRegistry
  alias Ezagent.ActionSet.Session, as: SessionBehavior
  alias Ezagent.Credential.UserDefaultSource
  alias Ezagent.Entity.Session
  alias Ezagent.Identity.RecipeCapBinding
  alias Ezagent.Session.AgentAdmissionSweeper
  alias EzagentDomainInstanceMessage.SessionCreator.AgentAdmission
  alias EzagentDomainInstanceMessage.SessionCreator.AgentAdmissionReconciliation
  alias EzagentDomainInstanceMessage.SessionCreator.AgentAdmissionState
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
        {:ok, _pid} ->
          :ok = inject_post_spawn_failure(uri)
          {:ok, [uri], %{fresh?: true, config_dir_path: nil}}

        {:error, {:already_started, _pid}} ->
          {:ok, [uri], %{fresh?: false}}

        {:error, {:already_registered, _}} ->
          {:ok, [uri], %{fresh?: false}}

        {:error, reason} ->
          {:error, reason}
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

    defp inject_post_spawn_failure(agent_uri) do
      case Process.get({__MODULE__, :post_spawn_failure}) do
        {:suspend_admission_write, controller} ->
          send(controller, {:candidate_spawned, self(), agent_uri})

          receive do
            {:continue_candidate_spawn, ^controller} -> :ok
          after
            5_000 -> {:error, :admission_write_fault_controller_timeout}
          end

        _ ->
          :ok
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
      Process.delete({CredentialTemplate, :post_spawn_failure})

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

  @tag :session_credential_isolation
  test "a later session requires a fresh credential admission even when the declaration is immediate and a default source exists",
       %{
         session_uri: session_uri,
         declarations: declarations,
         credential_flavor: credential_flavor
       } do
    assert {:ok, %{deferred: ["llm"]}} =
             DefinitionAgents.materialize_definition_agents(
               session_uri,
               @workspace_uri,
               @owner_uri,
               declarations
             )

    caps = Ezagent.Identity.list_caps_for(@owner_uri)
    assert {:ok, first} = AgentAdmission.begin(session_uri, "llm", @owner_uri, caps)
    first_uri = Ezagent.URI.new!(first.provisional_agent_uri)
    write_fake_credential!(first_uri)
    Process.put({CredentialTemplate, :credential_status}, :authenticated)

    assert {:ok, %{status: :joined}} =
             AgentAdmission.complete(
               session_uri,
               "llm",
               first.attempt_id,
               {@owner_uri, caps}
             )

    assert is_nil(
             UserDefaultSource.resolve(
               URI.to_string(@owner_uri),
               "system",
               credential_flavor
             )
           )

    set_default_source!(first_uri, credential_flavor)

    assert first.provisional_agent_uri ==
             UserDefaultSource.resolve(URI.to_string(@owner_uri), "system", credential_flavor)

    second_session = live_session("fresh-auth-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      AgentAdmission.list(second_session)
      |> Enum.each(fn
        %{provisional_agent_uri: uri} when is_binary(uri) -> terminate(Ezagent.URI.new!(uri))
        _admission -> :ok
      end)

      terminate(second_session)
    end)

    second_declarations =
      Enum.map(declarations, fn
        %{role_name: "llm"} = declaration ->
          %{declaration | credential_admission: :immediate}

        declaration ->
          declaration
      end)

    copy_declarations(second_session, second_declarations)

    assert {:ok, %{deferred: ["llm"]}} =
             DefinitionAgents.materialize_definition_agents(
               second_session,
               @workspace_uri,
               @owner_uri,
               second_declarations
             )

    assert [%{role_name: "llm", status: :pending_auth}] =
             AgentAdmission.list(second_session)

    assert SessionBehavior.role_name_to_uri(members_of(second_session), "llm") == nil

    assert {:ok, second} = AgentAdmission.begin(second_session, "llm", @owner_uri, caps)
    refute second.provisional_agent_uri == first.provisional_agent_uri
  end

  test "concurrent admission writes for different roles preserve both rows", %{
    session_uri: session_uri,
    declarations: declarations
  } do
    llm = Enum.find(declarations, &(&1.role_name == "llm"))
    gated_roles = for index <- 1..8, do: %{llm | role_name: "gated-#{index}"}
    replace_declarations(session_uri, gated_roles)
    parent = self()

    tasks =
      Enum.map(gated_roles, fn declaration ->
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            :write -> AgentAdmission.defer(session_uri, declaration)
          end
        end)
      end)

    Enum.each(tasks, fn task -> assert_receive {:ready, pid} when pid == task.pid end)
    Enum.each(tasks, &send(&1.pid, :write))
    Enum.each(tasks, &assert({:ok, _admission} = Task.await(&1, 10_000)))

    assert Enum.map(AgentAdmission.list(session_uri), & &1.role_name) ==
             Enum.map(gated_roles, & &1.role_name)
  end

  test "candidate admission is idempotent, validates credentials, retries, and joins", %{
    session_uri: session_uri,
    declarations: declarations
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

    assert is_nil(
             Ezagent.Credential.UserDefaultSource.resolve(
               URI.to_string(@owner_uri),
               "system",
               retrying.flavor
             )
           )
  end

  test "session reconciliation joins the authenticated original candidate", %{
    session_uri: session_uri,
    declarations: declarations
  } do
    assert {:ok, _summary} =
             DefinitionAgents.materialize_definition_agents(
               session_uri,
               @workspace_uri,
               @owner_uri,
               declarations
             )

    caps = Ezagent.Identity.list_caps_for(@owner_uri)
    assert {:ok, authenticating} = AgentAdmission.begin(session_uri, "llm", @owner_uri, caps)
    candidate_uri = Ezagent.URI.new!(authenticating.provisional_agent_uri)
    Process.put({CredentialTemplate, :credential_status}, :authenticated)

    assert :ok = AgentAdmission.reconcile(session_uri)

    assert [%{status: :joined, provisional_agent_uri: candidate}] =
             AgentAdmission.list(session_uri)

    assert candidate == URI.to_string(candidate_uri)
    assert SessionBehavior.role_name_to_uri(members_of(session_uri), "llm") == candidate_uri
  end

  test "session reconciliation preserves missing and unknown candidates", %{
    session_uri: session_uri,
    declarations: declarations
  } do
    assert {:ok, _summary} =
             DefinitionAgents.materialize_definition_agents(
               session_uri,
               @workspace_uri,
               @owner_uri,
               declarations
             )

    caps = Ezagent.Identity.list_caps_for(@owner_uri)
    assert {:ok, authenticating} = AgentAdmission.begin(session_uri, "llm", @owner_uri, caps)

    Process.put({CredentialTemplate, :credential_status}, :missing)
    assert :ok = AgentAdmission.reconcile(session_uri)
    assert AgentAdmission.list(session_uri) == [authenticating]

    Process.put({CredentialTemplate, :credential_status}, :unknown)
    assert :ok = AgentAdmission.reconcile(session_uri)
    assert AgentAdmission.list(session_uri) == [authenticating]
  end

  test "session reconciliation never inspects another session's candidate", %{
    session_uri: session_uri,
    declarations: declarations
  } do
    assert {:ok, _summary} =
             DefinitionAgents.materialize_definition_agents(
               session_uri,
               @workspace_uri,
               @owner_uri,
               declarations
             )

    caps = Ezagent.Identity.list_caps_for(@owner_uri)
    assert {:ok, current} = AgentAdmission.begin(session_uri, "llm", @owner_uri, caps)

    other_session = live_session("reconcile-scope-#{System.unique_integer([:positive])}")
    copy_declarations(other_session, declarations)

    on_exit(fn ->
      AgentAdmission.list(other_session)
      |> Enum.each(fn
        %{provisional_agent_uri: uri} when is_binary(uri) -> terminate(Ezagent.URI.new!(uri))
        _admission -> :ok
      end)

      terminate(other_session)
    end)

    llm = Enum.find(declarations, &(&1.role_name == "llm"))
    assert {:ok, %{status: :pending_auth}} = AgentAdmission.defer(other_session, llm)
    assert {:ok, other} = AgentAdmission.begin(other_session, "llm", @owner_uri, caps)

    Process.put({CredentialTemplate, :credential_status}, :authenticated)
    assert :ok = AgentAdmission.reconcile(session_uri)

    assert [%{status: :joined, attempt_id: current_attempt}] =
             AgentAdmission.list(session_uri)

    assert current_attempt == current.attempt_id

    assert [%{status: :authenticating, attempt_id: other_attempt}] =
             AgentAdmission.list(other_session)

    assert other_attempt == other.attempt_id
  end

  test "the supervised sweeper expires authenticating candidates and repeated sweeps are idempotent",
       %{
         session_uri: session_uri,
         declarations: declarations
       } do
    llm = Enum.find(declarations, &(&1.role_name == "llm"))
    assert {:ok, %{status: :pending_auth}} = AgentAdmission.defer(session_uri, llm)

    caps = Ezagent.Identity.list_caps_for(@owner_uri)
    assert {:ok, authenticating} = AgentAdmission.begin(session_uri, "llm", @owner_uri, caps)
    candidate_uri = Ezagent.URI.new!(authenticating.provisional_agent_uri)
    future = DateTime.add(DateTime.utc_now(), 1, :day)

    start_supervised!({AgentAdmissionSweeper, name: nil, interval: 10, now: fn -> future end})

    assert eventually(fn ->
             match?(
               [%{status: :failed, failure_code: :connection_timed_out}],
               AgentAdmission.list(session_uri)
             )
           end)

    assert eventually(fn -> not Ezagent.Kind.alive?(candidate_uri) end)
    assert AgentAdmissionSweeper.run_due(future) == []
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

    first_uri = Ezagent.URI.new!(first.provisional_agent_uri)
    set_default_source!(first_uri, credential_flavor)
    source = first.provisional_agent_uri

    assert {:ok, cancelled} =
             AgentAdmission.cancel(
               second_session,
               "llm",
               cancelling.attempt_id,
               {@owner_uri, Ezagent.Identity.list_caps_for(@owner_uri)}
             )

    assert cancelled.failure_code == :connection_cancelled
    assert eventually(fn -> not Ezagent.Kind.alive?(cancelling_uri) end)

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

  test "default-source resolver drift does not affect session-local completion", %{
    session_uri: session_uri,
    declarations: declarations
  } do
    assert {:ok, _summary} =
             DefinitionAgents.materialize_definition_agents(
               session_uri,
               @workspace_uri,
               @owner_uri,
               declarations
             )

    caps = Ezagent.Identity.list_caps_for(@owner_uri)
    assert {:ok, authenticating} = AgentAdmission.begin(session_uri, "llm", @owner_uri, caps)
    agent_uri = Ezagent.URI.new!(authenticating.provisional_agent_uri)
    wrong_root = Ezagent.URI.user("system", "wrong-admission-root")

    Process.put({CredentialTemplate, :credential_status}, :authenticated)
    restore_flavor_resolver = inject_pointer_failure(agent_uri, authenticating.flavor, wrong_root)

    assert {:ok, %{status: :joined}} =
             AgentAdmission.complete(
               session_uri,
               "llm",
               authenticating.attempt_id,
               {@owner_uri, Ezagent.Identity.list_caps_for(@owner_uri)}
             )

    assert SessionBehavior.role_name_to_uri(members_of(session_uri), "llm") == agent_uri

    assert is_nil(
             UserDefaultSource.resolve(URI.to_string(@owner_uri), "system", authenticating.flavor)
           )

    restore_flavor_resolver.()
  end

  test "joined-write failure retires the candidate without changing a prior default source", %{
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
    assert {:ok, first} = AgentAdmission.begin(session_uri, "llm", @owner_uri, caps)

    retry_session = live_session("pointer-restore-#{System.unique_integer([:positive])}")
    on_exit(fn -> terminate(retry_session) end)
    copy_declarations(retry_session, declarations)
    llm_declaration = Enum.find(declarations, &(&1.role_name == "llm"))

    assert {:ok, %{status: :pending_auth}} = AgentAdmission.defer(retry_session, llm_declaration)
    assert {:ok, candidate} = AgentAdmission.begin(retry_session, "llm", @owner_uri, caps)
    candidate_uri = Ezagent.URI.new!(candidate.provisional_agent_uri)

    Process.put({CredentialTemplate, :credential_status}, :authenticated)

    assert {:ok, %{status: :joined}} =
             AgentAdmission.complete(session_uri, "llm", first.attempt_id, {@owner_uri, caps})

    set_default_source!(Ezagent.URI.new!(first.provisional_agent_uri), credential_flavor)

    prior_source =
      UserDefaultSource.resolve(URI.to_string(@owner_uri), "system", credential_flavor)

    assert prior_source == first.provisional_agent_uri

    prior_fault = Application.get_env(:ezagent_domain_session, :agent_admission_put_joined_fault)

    Application.put_env(
      :ezagent_domain_session,
      :agent_admission_put_joined_fault,
      :injected_join_write_failure
    )

    on_exit(fn ->
      if is_nil(prior_fault) do
        Application.delete_env(:ezagent_domain_session, :agent_admission_put_joined_fault)
      else
        Application.put_env(
          :ezagent_domain_session,
          :agent_admission_put_joined_fault,
          prior_fault
        )
      end
    end)

    assert {:error, :injected_join_write_failure} =
             AgentAdmission.complete(
               retry_session,
               "llm",
               candidate.attempt_id,
               {@owner_uri, caps}
             )

    assert UserDefaultSource.resolve(URI.to_string(@owner_uri), "system", credential_flavor) ==
             prior_source

    refute UserDefaultSource.resolve(URI.to_string(@owner_uri), "system", credential_flavor) ==
             URI.to_string(candidate_uri)

    refute Ezagent.Kind.alive?(candidate_uri)
  end

  test "a queued newer completion succeeds after a stale candidate compensates", %{
    session_uri: session_uri,
    declarations: declarations
  } do
    assert {:ok, _summary} =
             DefinitionAgents.materialize_definition_agents(
               session_uri,
               @workspace_uri,
               @owner_uri,
               declarations
             )

    caps = Ezagent.Identity.list_caps_for(@owner_uri)
    assert {:ok, first} = AgentAdmission.begin(session_uri, "llm", @owner_uri, caps)

    stale_session = live_session("stale-compensation-#{System.unique_integer([:positive])}")
    newer_session = live_session("newer-completion-#{System.unique_integer([:positive])}")
    on_exit(fn -> terminate(stale_session) end)
    on_exit(fn -> terminate(newer_session) end)

    copy_declarations(stale_session, declarations)
    copy_declarations(newer_session, declarations)
    llm_declaration = Enum.find(declarations, &(&1.role_name == "llm"))

    assert {:ok, %{status: :pending_auth}} = AgentAdmission.defer(stale_session, llm_declaration)
    assert {:ok, stale} = AgentAdmission.begin(stale_session, "llm", @owner_uri, caps)

    assert {:ok, %{status: :pending_auth}} = AgentAdmission.defer(newer_session, llm_declaration)
    assert {:ok, newer} = AgentAdmission.begin(newer_session, "llm", @owner_uri, caps)
    newer_uri = Ezagent.URI.new!(newer.provisional_agent_uri)

    Process.put({CredentialTemplate, :credential_status}, :authenticated)

    assert {:ok, %{status: :joined}} =
             AgentAdmission.complete(session_uri, "llm", first.attempt_id, {@owner_uri, caps})

    prior_fault = Application.get_env(:ezagent_domain_session, :agent_admission_put_joined_fault)
    test_pid = self()

    Application.put_env(:ezagent_domain_session, :agent_admission_put_joined_fault, fn current ->
      if current.attempt_id == stale.attempt_id do
        task =
          Task.async(fn ->
            Process.put({CredentialTemplate, :credential_status}, :authenticated)
            send(test_pid, :newer_completion_queued)

            AgentAdmission.complete(
              newer_session,
              "llm",
              newer.attempt_id,
              {@owner_uri, caps}
            )
          end)

        send(test_pid, {:newer_completion_task, task})

        receive do
          :newer_joined_write_reached -> :ok
        after
          250 -> :ok
        end

        {:error, :injected_stale_join_failure}
      else
        send(test_pid, :newer_joined_write_reached)
        :ok
      end
    end)

    on_exit(fn ->
      if is_nil(prior_fault) do
        Application.delete_env(:ezagent_domain_session, :agent_admission_put_joined_fault)
      else
        Application.put_env(
          :ezagent_domain_session,
          :agent_admission_put_joined_fault,
          prior_fault
        )
      end
    end)

    assert {:error, :injected_stale_join_failure} =
             AgentAdmission.complete(stale_session, "llm", stale.attempt_id, {@owner_uri, caps})

    assert_receive :newer_completion_queued
    assert_receive {:newer_completion_task, task}
    assert {:ok, %{status: :joined}} = Task.await(task, 10_000)

    assert is_nil(UserDefaultSource.resolve(URI.to_string(@owner_uri), "system", newer.flavor))

    assert SessionBehavior.role_name_to_uri(members_of(newer_session), "llm") == newer_uri
  end

  test "an external default source remains unchanged after admission completion", %{
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

    assert {:ok, first} = AgentAdmission.begin(session_uri, "llm", @owner_uri, caps)

    candidate_session = live_session("pointer-cas-#{System.unique_integer([:positive])}")
    external_session = live_session("pointer-external-#{System.unique_integer([:positive])}")
    on_exit(fn -> terminate(candidate_session) end)
    on_exit(fn -> terminate(external_session) end)

    copy_declarations(candidate_session, declarations)
    copy_declarations(external_session, declarations)
    llm_declaration = Enum.find(declarations, &(&1.role_name == "llm"))

    assert {:ok, %{status: :pending_auth}} =
             AgentAdmission.defer(candidate_session, llm_declaration)

    assert {:ok, candidate} = AgentAdmission.begin(candidate_session, "llm", @owner_uri, caps)

    assert {:ok, %{status: :pending_auth}} =
             AgentAdmission.defer(external_session, llm_declaration)

    assert {:ok, external} = AgentAdmission.begin(external_session, "llm", @owner_uri, caps)
    external_uri = external.provisional_agent_uri
    set_default_source!(Ezagent.URI.new!(external_uri), credential_flavor)

    Process.put({CredentialTemplate, :credential_status}, :authenticated)

    assert {:ok, %{status: :joined}} =
             AgentAdmission.complete(session_uri, "llm", first.attempt_id, {@owner_uri, caps})

    assert {:ok, %{status: :joined}} =
             AgentAdmission.complete(
               candidate_session,
               "llm",
               candidate.attempt_id,
               {@owner_uri, caps}
             )

    assert UserDefaultSource.resolve(URI.to_string(@owner_uri), "system", credential_flavor) ==
             external_uri
  end

  test "joined-write cleanup failure preserves the session-local candidate for recovery", %{
    session_uri: session_uri,
    declarations: declarations
  } do
    assert {:ok, _summary} =
             DefinitionAgents.materialize_definition_agents(
               session_uri,
               @workspace_uri,
               @owner_uri,
               declarations
             )

    caps = Ezagent.Identity.list_caps_for(@owner_uri)

    retry_session = live_session("cleanup-reapply-#{System.unique_integer([:positive])}")
    on_exit(fn -> terminate(retry_session) end)
    copy_declarations(retry_session, declarations)
    llm_declaration = Enum.find(declarations, &(&1.role_name == "llm"))

    assert {:ok, %{status: :pending_auth}} = AgentAdmission.defer(retry_session, llm_declaration)
    assert {:ok, candidate} = AgentAdmission.begin(retry_session, "llm", @owner_uri, caps)
    candidate_uri = Ezagent.URI.new!(candidate.provisional_agent_uri)

    Process.put({CredentialTemplate, :credential_status}, :authenticated)

    prior_fault = Application.get_env(:ezagent_domain_session, :agent_admission_put_joined_fault)

    Application.put_env(:ezagent_domain_session, :agent_admission_put_joined_fault, fn current ->
      if current.attempt_id == candidate.attempt_id do
        :ok = Ezagent.Agent.CreationInventory.delete_winner(candidate_uri)
        {:error, :injected_join_write_failure}
      else
        :ok
      end
    end)

    on_exit(fn ->
      if is_nil(prior_fault) do
        Application.delete_env(:ezagent_domain_session, :agent_admission_put_joined_fault)
      else
        Application.put_env(
          :ezagent_domain_session,
          :agent_admission_put_joined_fault,
          prior_fault
        )
      end
    end)

    assert {:error, {:injected_join_write_failure, :creation_attempt_not_found}} =
             AgentAdmission.complete(
               retry_session,
               "llm",
               candidate.attempt_id,
               {@owner_uri, caps}
             )

    assert is_nil(
             UserDefaultSource.resolve(URI.to_string(@owner_uri), "system", candidate.flavor)
           )

    assert SessionBehavior.role_name_to_uri(members_of(retry_session), "llm") == candidate_uri
    assert Ezagent.Kind.alive?(candidate_uri)

    assert {:ok, :inserted} =
             Ezagent.Agent.CreationInventory.record_exact(
               EzagentCore.Repo,
               candidate.attempt_id,
               candidate_uri,
               @owner_uri,
               @workspace_uri
             )

    assert :ok =
             DefinitionAgents.cleanup_provisional(
               retry_session,
               @owner_uri,
               candidate_uri,
               candidate.attempt_id,
               actor_ctx(),
               :test_cleanup
             )
  end

  test "admission record failure preserves cleanup failure evidence", %{
    session_uri: session_uri,
    declarations: declarations
  } do
    assert {:ok, _summary} =
             DefinitionAgents.materialize_definition_agents(
               session_uri,
               @workspace_uri,
               @owner_uri,
               declarations
             )

    wrong_root = Ezagent.URI.user("system", "wrong-admission-record-root")
    test_pid = self()
    {:ok, session_pid} = Ezagent.KindRegistry.lookup(session_uri)

    controller =
      spawn(fn ->
        test_monitor = Process.monitor(test_pid)

        receive do
          {:candidate_spawned, begin_pid, agent_uri} ->
            :ok = :sys.suspend(session_pid)
            send(begin_pid, {:continue_candidate_spawn, self()})
            :ok = wait_for_admission_write(begin_pid)
            :ok = Ezagent.AgentLineage.rollback_lineage_fact(agent_uri, @owner_uri)

            {:ok, _status} =
              Ezagent.AgentLineage.record_exact(EzagentCore.Repo, agent_uri, wrong_root)

            :ok = Ezagent.AgentLineage.publish_cache(agent_uri, wrong_root)
            send(test_pid, {:admission_write_suspended, self(), agent_uri})

            receive do
              :resume_session ->
                :ok = :sys.resume(session_pid)
                send(test_pid, {:admission_session_resumed, self()})

              {:DOWN, ^test_monitor, :process, ^test_pid, _reason} ->
                :ok = :sys.resume(session_pid)
            end
        end
      end)

    Process.put(
      {CredentialTemplate, :post_spawn_failure},
      {:suspend_admission_write, controller}
    )

    assert {:error,
            {
              {:agent_admission_record_failed, {:agent_admission_write_failed, _write_failure}},
              {:cleanup_failed, {:provisional_lineage_mismatch, ^wrong_root}}
            }} =
             AgentAdmission.begin(
               session_uri,
               "llm",
               @owner_uri,
               Ezagent.Identity.list_caps_for(@owner_uri)
             )

    assert_receive {:admission_write_suspended, ^controller, agent_uri}
    send(controller, :resume_session)
    assert_receive {:admission_session_resumed, ^controller}
    assert Ezagent.Kind.alive?(agent_uri)
    assert :ok = Ezagent.Kind.terminate(agent_uri)
  end

  test "cleanup validates the exact attempt before tombstoning or removing membership", %{
    session_uri: session_uri,
    declarations: declarations
  } do
    assert {:ok, _summary} =
             DefinitionAgents.materialize_definition_agents(
               session_uri,
               @workspace_uri,
               @owner_uri,
               declarations
             )

    caps = Ezagent.Identity.list_caps_for(@owner_uri)
    assert {:ok, authenticating} = AgentAdmission.begin(session_uri, "llm", @owner_uri, caps)
    agent_uri = Ezagent.URI.new!(authenticating.provisional_agent_uri)
    Process.put({CredentialTemplate, :credential_status}, :authenticated)

    assert {:ok, %{status: :joined}} =
             AgentAdmission.complete(
               session_uri,
               "llm",
               authenticating.attempt_id,
               {@owner_uri, Ezagent.Identity.list_caps_for(@owner_uri)}
             )

    assert {:ok, binding} = RecipeCapBinding.fetch(agent_uri)

    assert {:error, :creation_attempt_not_found} =
             DefinitionAgents.cleanup_provisional(
               session_uri,
               @owner_uri,
               agent_uri,
               Ecto.UUID.generate(),
               actor_ctx(),
               :wrong_attempt
             )

    assert {:ok, ^binding} = RecipeCapBinding.fetch(agent_uri)
    assert SessionBehavior.role_name_to_uri(members_of(session_uri), "llm") == agent_uri
    assert Ezagent.Kind.alive?(agent_uri)
  end

  test "a joined gated agent whose credential fails returns to pending_auth", %{
    session_uri: session_uri,
    declarations: declarations
  } do
    assert {:ok, _summary} =
             DefinitionAgents.materialize_definition_agents(
               session_uri,
               @workspace_uri,
               @owner_uri,
               declarations
             )

    front_desk_uri = SessionBehavior.role_name_to_uri(members_of(session_uri), "front-desk")
    caps = Ezagent.Identity.list_caps_for(@owner_uri)
    assert {:ok, authenticating} = AgentAdmission.begin(session_uri, "llm", @owner_uri, caps)
    agent_uri = Ezagent.URI.new!(authenticating.provisional_agent_uri)
    Process.put({CredentialTemplate, :credential_status}, :authenticated)

    assert {:ok, %{status: :joined}} =
             AgentAdmission.complete(
               session_uri,
               "llm",
               authenticating.attempt_id,
               {@owner_uri, caps}
             )

    assert is_nil(
             UserDefaultSource.resolve(
               URI.to_string(@owner_uri),
               "system",
               authenticating.flavor
             )
           )

    Process.put({CredentialTemplate, :credential_status}, :missing)

    _results = AgentAdmissionSweeper.run_due(DateTime.utc_now())

    assert [
             %{
               role_name: "llm",
               status: :pending_auth,
               attempt_id: nil,
               provisional_agent_uri: nil,
               failure_code: :authentication_failed
             }
           ] = AgentAdmission.list(session_uri)

    assert SessionBehavior.role_name_to_uri(members_of(session_uri), "llm") == nil

    assert SessionBehavior.role_name_to_uri(members_of(session_uri), "front-desk") ==
             front_desk_uri

    assert eventually(fn -> not Ezagent.Kind.alive?(agent_uri) end)

    assert is_nil(
             UserDefaultSource.resolve(
               URI.to_string(@owner_uri),
               "system",
               authenticating.flavor
             )
           )

    assert {:ok, %{deferred: ["llm"]}} =
             DefinitionAgents.materialize_definition_agents(
               session_uri,
               @workspace_uri,
               @owner_uri,
               declarations
             )

    assert SessionBehavior.role_name_to_uri(members_of(session_uri), "llm") == nil
  end

  test "credential reconciliation ignores a non-admission agent", %{
    declarations: declarations
  } do
    assert {:ok, _summary} =
             DefinitionAgents.materialize_definition_agents(
               session_uri = live_session("ordinary-#{System.unique_integer([:positive])}"),
               @workspace_uri,
               @owner_uri,
               [hd(declarations)]
             )

    on_exit(fn -> terminate(session_uri) end)
    ordinary_uri = SessionBehavior.role_name_to_uri(members_of(session_uri), "front-desk")

    assert :ok = AgentAdmission.reconcile_auth_failure(ordinary_uri)
    assert SessionBehavior.role_name_to_uri(members_of(session_uri), "front-desk") == ordinary_uri
    assert Ezagent.Kind.alive?(ordinary_uri)
  end

  test "the sweeper retries a pending credential reconciliation after cleanup recovers", %{
    session_uri: session_uri,
    declarations: declarations
  } do
    assert {:ok, _summary} =
             DefinitionAgents.materialize_definition_agents(
               session_uri,
               @workspace_uri,
               @owner_uri,
               declarations
             )

    caps = Ezagent.Identity.list_caps_for(@owner_uri)
    assert {:ok, authenticating} = AgentAdmission.begin(session_uri, "llm", @owner_uri, caps)
    agent_uri = Ezagent.URI.new!(authenticating.provisional_agent_uri)
    Process.put({CredentialTemplate, :credential_status}, :authenticated)

    assert {:ok, %{status: :joined}} =
             AgentAdmission.complete(
               session_uri,
               "llm",
               authenticating.attempt_id,
               {@owner_uri, caps}
             )

    wrong_root = Ezagent.URI.user("system", "wrong-reconciliation-root")
    :ok = Ezagent.AgentLineage.rollback_lineage_fact(agent_uri, @owner_uri)

    assert {:ok, _status} =
             Ezagent.AgentLineage.record_exact(EzagentCore.Repo, agent_uri, wrong_root)

    :ok = Ezagent.AgentLineage.publish_cache(agent_uri, wrong_root)
    Process.put({CredentialTemplate, :credential_status}, :missing)

    assert {:error, {:provisional_lineage_mismatch, ^wrong_root}} =
             AgentAdmissionReconciliation.revalidate_joined(
               session_uri,
               hd(AgentAdmission.list(session_uri))
             )

    assert [
             %{
               status: :pending_auth,
               failure_code: :authentication_failed,
               attempt_id: attempt_id,
               provisional_agent_uri: provisional_agent_uri
             }
           ] = AgentAdmission.list(session_uri)

    assert is_binary(attempt_id)
    assert provisional_agent_uri == URI.to_string(agent_uri)

    :ok = Ezagent.AgentLineage.rollback_lineage_fact(agent_uri, wrong_root)

    assert {:ok, _status} =
             Ezagent.AgentLineage.record_exact(EzagentCore.Repo, agent_uri, @owner_uri)

    :ok = Ezagent.AgentLineage.publish_cache(agent_uri, @owner_uri)

    _results = AgentAdmissionSweeper.run_due(DateTime.utc_now())

    assert [
             %{
               status: :pending_auth,
               failure_code: :authentication_failed,
               attempt_id: nil,
               provisional_agent_uri: nil
             }
           ] = AgentAdmission.list(session_uri)

    assert eventually(fn -> not Ezagent.Kind.alive?(agent_uri) end)
  end

  test "the sweeper finalizes reconciliation when cleanup completed before the final write", %{
    session_uri: session_uri,
    declarations: declarations
  } do
    assert {:ok, _summary} =
             DefinitionAgents.materialize_definition_agents(
               session_uri,
               @workspace_uri,
               @owner_uri,
               declarations
             )

    caps = Ezagent.Identity.list_caps_for(@owner_uri)
    assert {:ok, authenticating} = AgentAdmission.begin(session_uri, "llm", @owner_uri, caps)
    agent_uri = Ezagent.URI.new!(authenticating.provisional_agent_uri)
    Process.put({CredentialTemplate, :credential_status}, :authenticated)

    assert {:ok, joined} =
             AgentAdmission.complete(
               session_uri,
               "llm",
               authenticating.attempt_id,
               {@owner_uri, caps}
             )

    reconciling =
      joined
      |> Map.put(:status, :pending_auth)
      |> Map.put(:expires_at, nil)
      |> Map.put(:failure_code, :authentication_failed)

    assert :ok = AgentAdmissionState.put_admission(session_uri, reconciling)

    assert :ok =
             DefinitionAgents.cleanup_provisional(
               session_uri,
               @owner_uri,
               agent_uri,
               joined.attempt_id,
               actor_ctx(),
               :credential_auth_failed
             )

    assert eventually(fn -> not Ezagent.Kind.alive?(agent_uri) end)
    _results = AgentAdmissionSweeper.run_due(DateTime.utc_now())

    assert [
             %{
               status: :pending_auth,
               failure_code: :authentication_failed,
               attempt_id: nil,
               provisional_agent_uri: nil
             }
           ] = AgentAdmission.list(session_uri)
  end

  test "gated materialization expires an active row after declaration revision and flavor drift",
       %{
         session_uri: session_uri,
         declarations: declarations
       } do
    assert {:ok, _summary} =
             DefinitionAgents.materialize_definition_agents(
               session_uri,
               @workspace_uri,
               @owner_uri,
               declarations
             )

    caps = Ezagent.Identity.list_caps_for(@owner_uri)
    assert {:ok, authenticating} = AgentAdmission.begin(session_uri, "llm", @owner_uri, caps)
    stale_agent_uri = Ezagent.URI.new!(authenticating.provisional_agent_uri)

    n = System.unique_integer([:positive])
    replacement_flavor = register_flavor("replacement", n, CredentialTemplate)

    current_declarations =
      Enum.map(declarations, fn
        %{role_name: "llm"} = declaration -> %{declaration | flavor: replacement_flavor}
        declaration -> declaration
      end)

    update_declarations(session_uri, current_declarations)

    assert {:ok, %{deferred: ["llm"]}} =
             DefinitionAgents.materialize_definition_agents(
               session_uri,
               @workspace_uri,
               @owner_uri,
               current_declarations
             )

    assert eventually(fn -> not Ezagent.Kind.alive?(stale_agent_uri) end)

    assert [
             %{
               role_name: "llm",
               flavor: ^replacement_flavor,
               status: :pending_auth,
               attempt_id: nil,
               provisional_agent_uri: nil
             }
           ] = AgentAdmission.list(session_uri)
  end

  test "begin and clear reject stale or forged declarations", %{
    session_uri: session_uri,
    declarations: declarations
  } do
    assert {:ok, _summary} =
             DefinitionAgents.materialize_definition_agents(
               session_uri,
               @workspace_uri,
               @owner_uri,
               declarations
             )

    caps = Ezagent.Identity.list_caps_for(@owner_uri)
    assert {:ok, authenticating} = AgentAdmission.begin(session_uri, "llm", @owner_uri, caps)
    Process.put({CredentialTemplate, :credential_status}, :authenticated)

    assert {:ok, %{status: :joined}} =
             AgentAdmission.complete(
               session_uri,
               "llm",
               authenticating.attempt_id,
               {@owner_uri, Ezagent.Identity.list_caps_for(@owner_uri)}
             )

    update_declarations(session_uri, declarations)

    assert {:error, :stale_agent_admission_declaration} =
             AgentAdmission.begin(session_uri, "llm", @owner_uri, caps)

    assert AgentAdmission.list(session_uri) == []

    llm_declaration = Enum.find(declarations, &(&1.role_name == "llm"))

    assert {:ok, %{status: :pending_auth}} =
             AgentAdmission.defer(session_uri, llm_declaration)

    update_declarations(session_uri, declarations)
    assert :ok = AgentAdmission.clear(session_uri, llm_declaration)
    assert AgentAdmission.list(session_uri) == []

    forged = %{llm_declaration | flavor: "forged-flavor"}

    assert {:error, :forged_agent_admission_declaration} =
             AgentAdmission.clear(session_uri, forged)
  end

  test "complete retires an active candidate whose declaration revision is stale", %{
    session_uri: session_uri,
    declarations: declarations
  } do
    assert {:ok, _summary} =
             DefinitionAgents.materialize_definition_agents(
               session_uri,
               @workspace_uri,
               @owner_uri,
               declarations
             )

    caps = Ezagent.Identity.list_caps_for(@owner_uri)
    assert {:ok, authenticating} = AgentAdmission.begin(session_uri, "llm", @owner_uri, caps)
    agent_uri = Ezagent.URI.new!(authenticating.provisional_agent_uri)
    update_declarations(session_uri, declarations)

    assert {:error, :stale_agent_admission_declaration} =
             AgentAdmission.complete(
               session_uri,
               "llm",
               authenticating.attempt_id,
               {@owner_uri, caps}
             )

    assert AgentAdmission.list(session_uri) == []
    assert eventually(fn -> not Ezagent.Kind.alive?(agent_uri) end)
  end

  test "cancel retires an active candidate whose declaration flavor is stale", %{
    session_uri: session_uri,
    declarations: declarations
  } do
    assert {:ok, _summary} =
             DefinitionAgents.materialize_definition_agents(
               session_uri,
               @workspace_uri,
               @owner_uri,
               declarations
             )

    caps = Ezagent.Identity.list_caps_for(@owner_uri)
    assert {:ok, authenticating} = AgentAdmission.begin(session_uri, "llm", @owner_uri, caps)
    agent_uri = Ezagent.URI.new!(authenticating.provisional_agent_uri)
    n = System.unique_integer([:positive])
    replacement_flavor = register_flavor("stale-cancel", n, CredentialTemplate)

    current_declarations =
      Enum.map(declarations, fn
        %{role_name: "llm"} = declaration -> %{declaration | flavor: replacement_flavor}
        declaration -> declaration
      end)

    replace_declarations(session_uri, current_declarations)

    assert {:error, :stale_agent_admission_declaration} =
             AgentAdmission.cancel(
               session_uri,
               "llm",
               authenticating.attempt_id,
               {@owner_uri, caps}
             )

    assert AgentAdmission.list(session_uri) == []
    assert eventually(fn -> not Ezagent.Kind.alive?(agent_uri) end)
  end

  test "expiry retires and clears an attempt whose declaration revision is stale", %{
    declarations: declarations
  } do
    session_uri = live_session("stale-expire-#{System.unique_integer([:positive])}")
    on_exit(fn -> terminate(session_uri) end)
    copy_declarations(session_uri, declarations)
    llm_declaration = Enum.find(declarations, &(&1.role_name == "llm"))

    assert {:ok, %{status: :pending_auth}} =
             AgentAdmission.defer(session_uri, llm_declaration)

    assert {:ok, authenticating} =
             AgentAdmission.begin(
               session_uri,
               "llm",
               @owner_uri,
               Ezagent.Identity.list_caps_for(@owner_uri)
             )

    agent_uri = Ezagent.URI.new!(authenticating.provisional_agent_uri)
    update_declarations(session_uri, declarations)

    assert {:ok, %{status: :failed, failure_code: :connection_timed_out}} =
             AgentAdmission.expire(session_uri, authenticating.attempt_id)

    assert AgentAdmission.list(session_uri) == []
    assert eventually(fn -> not Ezagent.Kind.alive?(agent_uri) end)
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

  defp update_declarations(session_uri, declarations) do
    n = System.unique_integer([:positive])

    working_copy =
      session_uri
      |> Session.read_template_working_copy()
      |> Map.put(
        :session_template_uri,
        Ezagent.URI.template("system", :session, "hello@revision-#{n}")
      )
      |> Map.put(:member_declarations, declarations)

    assert {:ok, _} = SessionBehavior.system_set_working_copy(session_uri, working_copy)
  end

  defp replace_declarations(session_uri, declarations) do
    working_copy =
      session_uri
      |> Session.read_template_working_copy()
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

  defp actor_ctx do
    %{
      caller: @owner_uri,
      authenticated_principal: @owner_uri,
      caps: Ezagent.Identity.list_caps_for(@owner_uri)
    }
  end

  defp wait_for_admission_write(pid, attempts \\ 500)
  defp wait_for_admission_write(_pid, 0), do: {:error, :admission_write_not_reached}

  defp wait_for_admission_write(pid, attempts) do
    case Process.info(pid, :current_stacktrace) do
      {:current_stacktrace, stacktrace} ->
        if Enum.any?(stacktrace, fn
             {AgentAdmissionState, :write_admissions, 2, _location} -> true
             _frame -> false
           end) do
          :ok
        else
          Process.sleep(10)
          wait_for_admission_write(pid, attempts - 1)
        end

      nil ->
        {:error, :admission_process_exited}
    end
  end

  defp set_default_source!(source_uri, flavor) do
    target =
      Ezagent.URI.with_action(
        @owner_uri,
        :user_default_credential_source,
        :set_default_credential_source
      )

    assert {:ok, write_cap} =
             Ezagent.Cap.issue_for_action({:admin, @owner_uri}, @owner_uri, target)

    ctx = %{
      caller: @owner_uri,
      authenticated_principal: @owner_uri,
      caps:
        @owner_uri
        |> Ezagent.Identity.list_caps_for()
        |> MapSet.new()
        |> MapSet.put(write_cap)
    }

    assert {:ok, _result} =
             UserDefaultSource.set_via_dispatch(
               @owner_uri,
               %{
                 flavor: flavor,
                 source_uri: URI.to_string(source_uri),
                 workspace: "system"
               },
               ctx
             )
  end

  defp inject_pointer_failure(agent_uri, expected_flavor, wrong_root) do
    table = Ezagent.UriQuery.table()
    [{:flavor, original}] = :ets.lookup(table, :flavor)
    counter = :atomics.new(1, [])
    agent_key = Ezagent.URI.stable_key(agent_uri)

    replacement = fn
      %URI{} = queried_uri ->
        if Ezagent.URI.stable_key(queried_uri) == agent_key do
          case :atomics.add_get(counter, 1, 1) do
            1 ->
              {:ok, expected_flavor}

            _pointer_validation ->
              :ok = Ezagent.AgentLineage.rollback_lineage_fact(agent_uri, @owner_uri)

              {:ok, _status} =
                Ezagent.AgentLineage.record_exact(EzagentCore.Repo, agent_uri, wrong_root)

              :ok = Ezagent.AgentLineage.publish_cache(agent_uri, wrong_root)
              {:ok, "wrong-flavor"}
          end
        else
          original.(queried_uri)
        end

      other ->
        original.(other)
    end

    true = :ets.insert(table, {:flavor, replacement})
    on_exit(fn -> :ets.insert(table, {:flavor, original}) end)
    fn -> :ets.insert(table, {:flavor, original}) end
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
