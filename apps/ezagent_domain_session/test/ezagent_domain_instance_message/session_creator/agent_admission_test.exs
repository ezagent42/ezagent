defmodule EzagentDomainInstanceMessage.SessionCreator.AgentAdmissionTest do
  use EzagentCore.DataCase, async: false

  import Ezagent.Test.CapHelper, only: [ensure_workspace_kind!: 1]

  alias Ezagent.Agent.RecipeRegistry
  alias Ezagent.ActionSet.Session, as: SessionBehavior
  alias Ezagent.Credential.UserDefaultSource
  alias Ezagent.Entity.Session
  alias Ezagent.Identity.RecipeCapBinding
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

  test "default-source failure never exposes joined and preserves cleanup failure evidence", %{
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

    assert {:error,
            {
              {:default_credential_source_failed, :source_flavor_mismatch},
              cleanup_failure
            }} =
             AgentAdmission.complete(
               session_uri,
               "llm",
               authenticating.attempt_id,
               {@owner_uri, Ezagent.Identity.list_caps_for(@owner_uri)}
             )

    assert cleanup_failure != nil
    refute Enum.any?(AgentAdmission.list(session_uri), &(&1.status == :joined))
    assert SessionBehavior.role_name_to_uri(members_of(session_uri), "llm") == agent_uri
    assert {:ok, binding} = RecipeCapBinding.fetch(agent_uri)

    restore_flavor_resolver.()
    :ok = Ezagent.AgentLineage.rollback_lineage_fact(agent_uri, wrong_root)
    {:ok, _status} = Ezagent.AgentLineage.record_with_status(agent_uri, @owner_uri)

    assert :ok =
             DefinitionAgents.cleanup_provisional(
               session_uri,
               @owner_uri,
               agent_uri,
               authenticating.attempt_id,
               actor_ctx(),
               :test_cleanup
             )

    assert binding.version > 0
  end

  test "post-pointer joined-write failure restores the prior default source", %{
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

  test "a queued newer completion wins after a stale candidate compensates", %{
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

    assert UserDefaultSource.resolve(URI.to_string(@owner_uri), "system", credential_flavor) ==
             URI.to_string(newer_uri)

    assert SessionBehavior.role_name_to_uri(members_of(newer_session), "llm") == newer_uri
  end

  test "cleanup failure reapplies the candidate default source after restoration", %{
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

    retry_session = live_session("cleanup-reapply-#{System.unique_integer([:positive])}")
    on_exit(fn -> terminate(retry_session) end)
    copy_declarations(retry_session, declarations)
    llm_declaration = Enum.find(declarations, &(&1.role_name == "llm"))

    assert {:ok, %{status: :pending_auth}} = AgentAdmission.defer(retry_session, llm_declaration)
    assert {:ok, candidate} = AgentAdmission.begin(retry_session, "llm", @owner_uri, caps)
    candidate_uri = Ezagent.URI.new!(candidate.provisional_agent_uri)

    Process.put({CredentialTemplate, :credential_status}, :authenticated)

    assert {:ok, %{status: :joined}} =
             AgentAdmission.complete(session_uri, "llm", first.attempt_id, {@owner_uri, caps})

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

    assert UserDefaultSource.resolve(URI.to_string(@owner_uri), "system", credential_flavor) ==
             URI.to_string(candidate_uri)

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
             {AgentAdmission, :write_admissions, 2, _location} -> true
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
