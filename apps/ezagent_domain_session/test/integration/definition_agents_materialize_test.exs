defmodule EzagentDomainInstanceMessage.Integration.DefinitionAgentsMaterializeTest do
  @moduledoc """
  T2-1b — `DefinitionAgents.materialize_definition_agents/4` turns a socialware
  `Definition`'s `agents` (`%{recipe, role_name}`) into LIVE session members that
  hold their recipe caps.

  The cc flavor is unregistered in the `domain_session` test env, so
  `spawn_from_template_content` spawns a bare `Entity.Agent` (no real claude
  sidecar) — enough to prove: (1) the agent joins as a member carrying its
  `role_name` facet, (2) the durable binding self-stores the recipe's
  `requested_caps` on the per-session agent URI, (3) idempotent re-materialize, (4) role_name
  uniqueness (batch + vs existing member) and (5) fail-closed on unknown recipe.
  """

  use EzagentCore.DataCase, async: false

  import Ecto.Query
  import Ezagent.Test.CapHelper, only: [ensure_workspace_kind!: 1]

  alias Ezagent.Agent.RecipeRegistry
  alias Ezagent.ActionSet.Session, as: SessionBehavior
  alias Ezagent.Entity.Session
  alias Ezagent.Identity.RecipeCapBinding
  alias Ezagent.Session.AgentAdmissionSweeper
  alias Ezagent.Socialware.CompositionBinding
  alias Ezagent.{Invocation, KindRegistry}
  alias EzagentCore.Repo
  alias EzagentDomainInstanceMessage.MaterializedRoleTestBehavior
  alias EzagentDomainInstanceMessage.SessionCreator
  alias EzagentDomainInstanceMessage.SessionCreator.AgentAdmission
  alias EzagentDomainInstanceMessage.SessionCreator.AgentAdmissionState
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

  # A flavor whose credential is an ENV VAR (like deepseek's API-key env var),
  # so the file-based pre-flight `CredentialPrecondition.check_source/3` waves it
  # through and the missing-credential surfaces only at spawn as
  # `{:backend_api_key_missing, profile, uri}`. Mirrors the real cc-custom
  # (deepseek-profile) orchestrator in a keyless env (every CI without the key).
  defmodule DeepseekMissingStubTemplate do
    @moduledoc false
    @behaviour Ezagent.Kind.Template

    @impl Ezagent.Kind.Template
    def template_name, do: "definition_agents.deepseek_missing_stub"

    @impl Ezagent.Kind.Template
    def validate(%{"agent_uri" => agent_uri}) when is_binary(agent_uri), do: :ok
    def validate(_), do: {:error, :invalid_deepseek_missing_stub_template}

    @impl Ezagent.Kind.Template
    def template_data_extra(content) when is_map(content) do
      case Ezagent.Kind.Template.content_field(content, :session_template_member) do
        true -> %{"session_template_member" => true}
        _ -> %{}
      end
    end

    @impl Ezagent.Kind.Template
    def instantiate(_name, %{"session_template_member" => member} = data, _workspace_uri)
        when member in [true, "true"] do
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

    def instantiate(_name, data, _workspace_uri) do
      {:error, {:backend_api_key_missing, "deepseek", Ezagent.URI.new!(data["agent_uri"])}}
    end
  end

  # An ENV-credential flavor whose probe is PROFILE-DRIVEN (mirrors cc-custom):
  # `credential_status/2` classifies on the `:backend_profile` opt — "kimi"
  # reads `MOONSHOT_API_KEY`; no/unknown profile → `:unknown` (fail closed).
  # Declares NO on-disk credential files, so `check_source` takes the
  # environment branch and the role slot's `provider` opt decides the verdict.
  defmodule EnvProfileStubTemplate do
    @moduledoc false
    @behaviour Ezagent.Kind.Template
    @behaviour Ezagent.Agent.CredentialAdapter

    # ENV-backed credential — NO on-disk credential files (mirrors
    # `FakeCcCustomTemplate`), so `check_source` takes the environment branch.
    @impl Ezagent.Agent.CredentialAdapter
    def credential_env_var, do: "MOONSHOT_API_KEY"

    @impl Ezagent.Agent.CredentialAdapter
    def credential_connection(_opts), do: {:api_key, "moonshot", "Configure test API key"}

    @impl Ezagent.Agent.CredentialAdapter
    def credential_relpaths, do: []

    @impl Ezagent.Agent.CredentialAdapter
    def secret_relpaths, do: []

    @impl Ezagent.Agent.CredentialAdapter
    def auth_failure_signals, do: []

    @impl Ezagent.Agent.CredentialAdapter
    def credential_status(_home, opts) do
      case Keyword.get(opts, :backend_profile) do
        "kimi" ->
          case System.get_env("MOONSHOT_API_KEY") do
            key when is_binary(key) and key != "" ->
              %{status: :authenticated, detail: nil, expires_at: nil}

            _ ->
              %{status: :missing, detail: "MOONSHOT_API_KEY not set", expires_at: nil}
          end

        _ ->
          %{status: :unknown, detail: nil, expires_at: nil}
      end
    end

    @impl Ezagent.Kind.Template
    def template_name, do: "definition_agents.env_profile_stub"

    @impl Ezagent.Kind.Template
    def validate(%{"agent_uri" => agent_uri}) when is_binary(agent_uri), do: :ok
    def validate(_), do: {:error, :invalid_env_profile_stub_template}

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

  defmodule PtyBootstrapStubTemplate do
    @moduledoc false
    @behaviour Ezagent.Kind.Template

    @impl Ezagent.Kind.Template
    def template_name, do: "definition_agents.pty_bootstrap_stub"

    def credential_connection(_opts), do: {:pty, "Connect test CLI"}

    @impl Ezagent.Kind.Template
    def template_data_extra(content) when is_map(content) do
      case Ezagent.Kind.Template.content_field(content, :credential_bootstrap) do
        nil -> %{}
        bootstrap -> %{"credential_bootstrap" => bootstrap}
      end
    end

    @impl Ezagent.Kind.Template
    def validate(%{"agent_uri" => agent_uri}) when is_binary(agent_uri), do: :ok
    def validate(_), do: {:error, :invalid_pty_bootstrap_stub_template}

    @impl Ezagent.Kind.Template
    def instantiate(_name, %{"credential_bootstrap" => bootstrap} = data, _workspace_uri)
        when bootstrap in [:pty, "pty"] do
      spawn_bare_agent(data)
    end

    def instantiate(_name, _data, _workspace_uri),
      do: {:error, :missing_pty_bootstrap_marker}

    defp spawn_bare_agent(data) do
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

  defmodule ApiKeyNoBootstrapStubTemplate do
    @moduledoc false
    @behaviour Ezagent.Kind.Template

    @impl Ezagent.Kind.Template
    def template_name, do: "definition_agents.api_key_no_bootstrap_stub"

    def credential_connection(_opts),
      do: {:api_key, "test-provider", "Configure test API key"}

    @impl Ezagent.Kind.Template
    def template_data_extra(content) when is_map(content) do
      case Ezagent.Kind.Template.content_field(content, :credential_bootstrap) do
        nil -> %{}
        bootstrap -> %{"credential_bootstrap" => bootstrap}
      end
    end

    @impl Ezagent.Kind.Template
    def validate(%{"agent_uri" => agent_uri}) when is_binary(agent_uri), do: :ok
    def validate(_), do: {:error, :invalid_api_key_no_bootstrap_stub_template}

    @impl Ezagent.Kind.Template
    def instantiate(_name, data, workspace_uri) do
      if Map.has_key?(data, "credential_bootstrap") do
        {:error, :unexpected_pty_bootstrap_marker}
      else
        PtyBootstrapStubTemplate.instantiate(
          template_name(),
          Map.put(data, "credential_bootstrap", :pty),
          workspace_uri
        )
      end
    end
  end

  # A SLICE-credentialled flavor (like curl: the key lives in the agent's
  # `:api_keys` slice — no config-home files, no env probe). Before #185 the
  # credential precondition waved every slice-backed flavor through, so a role
  # whose recipe marks the credential REQUIRED spawned keyless and the cascade's
  # `:no_credential_source` surfaced one layer later as a hard
  # `{:agent_spawn_failed, …}` that halted the whole batch. Now the precondition
  # pre-skips the slot loud (the same lane as a file-credential-missing role),
  # while a `credential_optional` recipe still spawns keyless.
  defmodule SliceStubTemplate do
    @moduledoc false
    @behaviour Ezagent.Kind.Template
    @behaviour Ezagent.Agent.CredentialSliceAdapter

    @impl Ezagent.Agent.CredentialSliceAdapter
    def credential_slice, do: :api_keys

    @impl Ezagent.Agent.CredentialSliceAdapter
    def materialize_credential_slice(_uri, _data), do: :ok

    @impl Ezagent.Kind.Template
    def template_name, do: "definition_agents.slice_stub"

    @impl Ezagent.Kind.Template
    def validate(%{"agent_uri" => agent_uri}) when is_binary(agent_uri), do: :ok
    def validate(_), do: {:error, :invalid_slice_stub_template}

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

  defmodule ConvergenceTimeoutTemplate do
    @moduledoc false
    @behaviour Ezagent.Kind.Template

    @namespace "definition-agents-rollback"

    @impl Ezagent.Kind.Template
    def template_name, do: "definition_agents.convergence_timeout"

    @impl Ezagent.Kind.Template
    def config_dir_namespace, do: @namespace

    @impl Ezagent.Kind.Template
    def validate(%{
          "class" => "definition_agents.convergence_timeout",
          "agent_uri" => agent_uri,
          "cwd" => cwd
        })
        when is_binary(agent_uri) and is_binary(cwd),
        do: :ok

    def validate(_), do: {:error, :invalid_definition_agents_convergence_timeout_template}

    @impl Ezagent.Kind.Template
    def instantiate(_name, data, _workspace_uri) do
      uri = Ezagent.URI.new!(data["agent_uri"])
      config_dir = Map.fetch!(data, "allocated_config_dir")

      case Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{
             uri: uri,
             behaviors: Ezagent.Entity.Agent.base_behaviors(),
             role: data["role"],
             config_dir_path: config_dir,
             template_class: __MODULE__,
             respawn_template_data: data
           }) do
        {:ok, _pid} ->
          :ok = File.write(Path.join(config_dir, "materialized"), "task-3 rollback fixture")
          :ok = apply_failure_mode(uri)
          send(self(), {:task_3_fresh_spawned, uri, config_dir})

          {:ok, [uri],
           %{
             fresh?: true,
             config_dir_path: config_dir,
             respawn_template_data: data
           }}

        {:error, {:already_started, _pid}} ->
          {:ok, [uri], %{fresh?: false}}

        {:error, {:already_registered, _}} ->
          {:ok, [uri], %{fresh?: false}}

        {:error, reason} ->
          {:error, reason}
      end
    end

    @impl Ezagent.Kind.Template
    def list_extensions(_config_dir), do: {:ok, []}

    @impl Ezagent.Kind.Template
    def toggle_extension(_config_dir, _extension_id, _enabled?), do: :ok

    @impl Ezagent.Kind.Template
    def destroy_config_dir(%URI{} = agent_uri, config_dir) when is_binary(config_dir) do
      if Process.get({__MODULE__, :failure_mode}) == :post_spawn_rollback_failure do
        {:error, :injected_config_cleanup_failure}
      else
        destroy_safe_config_dir(agent_uri, config_dir)
      end
    end

    defp destroy_safe_config_dir(agent_uri, config_dir) do
      if Ezagent.Sandbox.ConfigDir.safe_to_destroy?(config_dir, agent_uri, @namespace) do
        case File.rm_rf(config_dir) do
          {:ok, _removed} -> :ok
          {:error, reason, _path} -> {:error, reason}
        end
      else
        {:error, :unsafe_config_dir}
      end
    end

    defp apply_failure_mode(uri) do
      case Process.get({__MODULE__, :failure_mode}) do
        :convergence ->
          Ezagent.ReadyGate.put(uri, :not_ready)

        :post_spawn_rollback_failure ->
          Ezagent.ReadyGate.put(uri, :failed)

        {:join, session_uri, blocker_uri, role_name} ->
          join_blocker(session_uri, blocker_uri, role_name)

        _ ->
          :ok
      end
    end

    defp join_blocker(session_uri, blocker_uri, role_name) do
      _ = Ezagent.Domain.Agent.ensure_declared_member(blocker_uri)
      target = Ezagent.URI.with_action(session_uri, :session, :join)
      admin = Ezagent.Entity.User.admin_uri()
      {:ok, cap} = Ezagent.Cap.issue_for_action({:admin, admin}, admin, target)

      case Ezagent.Invocation.dispatch(%Ezagent.Invocation{
             target: target,
             mode: :call,
             args: %{member: blocker_uri, role_name: role_name},
             ctx: %{
               caller: admin,
               authenticated_principal: admin,
               caps: MapSet.new([cap]),
               reply: {:caller_inbox, self()}
             },
             origin: :trusted_internal
           }) do
        {:ok, %{status: status, member: ^blocker_uri}}
        when status in [:granted, :already_member] ->
          :ok

        other ->
          {:error, {:blocker_join_failed, other}}
      end
    end
  end

  defmodule FailingTemplate do
    @moduledoc false
    @behaviour Ezagent.Kind.Template

    @impl Ezagent.Kind.Template
    def template_name, do: "definition_agents.failing"

    @impl Ezagent.Kind.Template
    def validate(%{"class" => "definition_agents.failing"}), do: :ok
    def validate(_), do: {:error, :invalid_definition_agents_failing_template}

    @impl Ezagent.Kind.Template
    def instantiate(_name, _data, _workspace_uri), do: {:error, :synthetic_spawn_failure}
  end

  @workspace_uri URI.new!("workspace://system")
  @owner_uri URI.new!("entity://system/user/admin")
  @missing_behavior :"Elixir.EzagentDomainInstanceMessage.Task3MissingBehavior"

  setup context do
    if context[:terminate_system_workspace_before_fixture] do
      terminate(@workspace_uri)
    end

    created? = KindRegistry.lookup(@workspace_uri) == :error
    ensure_workspace_kind!(@workspace_uri)

    if created? do
      on_exit(fn -> terminate(@workspace_uri) end)
    end

    :ok
  end

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

  defp register_deepseek_missing_flavor(n) do
    flavor = "definition_agents_deepseek_missing_#{n}"

    :ok =
      Ezagent.AgentFlavorRegistry.register(%{
        flavor: flavor,
        kind: Ezagent.Entity.Agent,
        template_class: DeepseekMissingStubTemplate
      })

    flavor
  end

  defp register_env_profile_flavor(n) do
    flavor = "definition_agents_env_profile_#{n}"

    :ok =
      Ezagent.AgentFlavorRegistry.register(%{
        flavor: flavor,
        kind: Ezagent.Entity.Agent,
        template_class: EnvProfileStubTemplate
      })

    # EnvProfileStubTemplate is a CREDENTIALLED flavor (declares the full
    # CredentialAdapter declarative group), so `RecipeMaterializer.config_dir_ref/2`
    # resolves a config home through the FsResolver — register the stub's
    # `"<namespace>-agents"` type test-only (mirrors the plugin's
    # `config_dir_resource_types/1` shape). Tolerate an earlier identical
    # registration (first-writer-wins; only unregister when WE registered).
    type = "definition_agents.env_profile_stub-agents"

    case Ezagent.Resource.FsResolver.register_type(type, %{
           backend_component: type,
           authority: &Ezagent.Resource.FsResolver.config_dir_authority/2
         }) do
      :ok ->
        on_exit(fn -> Ezagent.Resource.FsResolver.unregister_type(type) end)

      {:error, {:already_registered, ^type}} ->
        :ok
    end

    flavor
  end

  defp register_connection_capture_flavor(n, connection) do
    {suffix, template_class} =
      case connection do
        :pty -> {"pty_bootstrap", PtyBootstrapStubTemplate}
        :api_key -> {"api_key_no_bootstrap", ApiKeyNoBootstrapStubTemplate}
      end

    flavor = "definition_agents_#{suffix}_#{n}"

    :ok =
      Ezagent.AgentFlavorRegistry.register(%{
        flavor: flavor,
        kind: Ezagent.Entity.Agent,
        template_class: template_class
      })

    flavor
  end

  defp register_slice_stub_flavor(n) do
    flavor = "definition_agents_slice_stub_#{n}"

    :ok =
      Ezagent.AgentFlavorRegistry.register(%{
        flavor: flavor,
        kind: Ezagent.Entity.Agent,
        template_class: SliceStubTemplate
      })

    flavor
  end

  defp register_failing_flavor(n) do
    flavor = "definition_agents_failing_#{n}"

    :ok =
      Ezagent.AgentFlavorRegistry.register(%{
        flavor: flavor,
        kind: Ezagent.Entity.Agent,
        template_class: FailingTemplate
      })

    flavor
  end

  defp register_convergence_timeout_flavor(n) do
    flavor = "definition_agents_convergence_timeout_#{n}"

    register_config_dir_type(ConvergenceTimeoutTemplate.config_dir_namespace())

    :ok =
      Ezagent.AgentFlavorRegistry.register(%{
        flavor: flavor,
        kind: Ezagent.Entity.Agent,
        template_class: ConvergenceTimeoutTemplate
      })

    flavor
  end

  defp register_config_dir_type(namespace) do
    type = "#{namespace}-agents"

    case Ezagent.Resource.FsResolver.register_type(type, %{
           backend_component: type,
           authority: &Ezagent.Resource.FsResolver.config_dir_authority/2
         }) do
      :ok ->
        on_exit(fn -> Ezagent.Resource.FsResolver.unregister_type(type) end)

      {:error, {:already_registered, ^type}} ->
        :ok
    end
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
      Ezagent.Kind.spawn(Session, %{
        uri: session_uri,
        behaviors: Session.behaviors(),
        owner_uri: @owner_uri
      })

    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, @workspace_uri)
    on_exit(fn -> terminate(session_uri) end)
    session_uri
  end

  defp live_session(n, %URI{} = workspace_uri, %URI{} = owner_uri) do
    workspace_name = Ezagent.URI.workspace_name!(workspace_uri)
    session_uri = Ezagent.URI.session(workspace_name, "generic", "reuse-race-#{n}")

    {:ok, _pid} =
      Ezagent.Kind.spawn(Session, %{
        uri: session_uri,
        behaviors: Session.behaviors(),
        owner_uri: owner_uri
      })

    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, workspace_uri)
    on_exit(fn -> terminate(session_uri) end)
    session_uri
  end

  defp confirmed_user(%URI{} = workspace_uri, prefix) do
    workspace_name = Ezagent.URI.workspace_name!(workspace_uri)
    user_uri = Ezagent.URI.user(workspace_name, "#{prefix}-#{uniq()}")
    {:ok, _row} = Ezagent.Users.create(user_uri, "pw-not-secret-#{uniq()}", [])
    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(user_uri)
    on_exit(fn -> terminate(user_uri) end)
    user_uri
  end

  defp reuse_working_copy(workspace_uri, n, declaration) do
    SessionBehavior.default_template_working_copy()
    |> Map.put(
      :session_template_uri,
      Ezagent.URI.template(
        Ezagent.URI.workspace_name!(workspace_uri),
        :session,
        "reuse@revision-#{n}"
      )
    )
    |> Map.put(:member_declarations, [declaration])
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

  defp seed_bind_failure_recipe(n) do
    name = "t3-bind-failure-#{n}"
    RecipeRegistry.invalidate(RecipeRegistry.system_workspace_uri(), name)

    {:ok, _} =
      RecipeRegistry.seed_role_if_absent(%{
        name: name,
        requested_caps: [
          %{behavior: @missing_behavior, action: :task_3_missing_action}
        ]
      })

    name
  end

  # #185 — a recipe carrying a `config` (e.g. the hello.llm shape's
  # `credential_optional` declaration), so the credential precondition reads
  # the SAME flag the cascade's `credential_required?/2` does.
  defp seed_recipe_with_config(n, config) when is_map(config) do
    name = "t2-cfg-#{n}"
    RecipeRegistry.invalidate(RecipeRegistry.system_workspace_uri(), name)

    {:ok, _} =
      RecipeRegistry.seed_role_if_absent(%{
        name: name,
        requested_caps: [
          %{behavior: Ezagent.ActionSet.Identity, action: :list_caps}
        ],
        config: config
      })

    name
  end

  defp seed_recipe_with_behavior(n) do
    name = "t2-behavior-#{n}"
    RecipeRegistry.invalidate(RecipeRegistry.system_workspace_uri(), name)

    {:ok, _} =
      RecipeRegistry.seed_role_if_absent(%{
        name: name,
        behaviors: [MaterializedRoleTestBehavior],
        requested_caps: [
          %{behavior: MaterializedRoleTestBehavior, action: :ping}
        ]
      })

    name
  end

  defp seed_passive_recipe(n) do
    name = "t2-passive-data-#{n}"
    RecipeRegistry.invalidate(RecipeRegistry.system_workspace_uri(), name)

    {:ok, _} =
      RecipeRegistry.seed_role_if_absent(%{
        name: name,
        passive: true,
        requested_caps: []
      })

    name
  end

  defp ensure_orchestrator_recipe do
    case RecipeRegistry.lookup(RecipeRegistry.system_workspace_uri(), "orchestrator") do
      {:ok, _recipe} ->
        :ok

      :error ->
        case RecipeRegistry.seed_role_if_absent(%{name: "orchestrator", requested_caps: []}) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp live_agent(n, recipe_name) do
    agent_uri = Ezagent.URI.agent("system", "reusable-#{n}")

    {:ok, _pid} =
      Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{
        uri: agent_uri,
        behaviors: Ezagent.Entity.Agent.base_behaviors()
      })

    :ok = Ezagent.WorkspaceRegistry.bind(agent_uri, @workspace_uri)
    :ok = Ezagent.Agent.RecipeAttributes.put(agent_uri, recipe_name)
    on_exit(fn -> terminate(agent_uri) end)
    agent_uri
  end

  defp live_agent(n, recipe_name, flavor) when is_binary(flavor) do
    agent_uri = live_agent(n, recipe_name)
    :ok = Ezagent.AgentFlavorAttributes.put(agent_uri, flavor)
    agent_uri
  end

  defp live_agent(n, recipe_name, %URI{} = workspace_uri) do
    workspace_name = Ezagent.URI.workspace_name!(workspace_uri)
    agent_uri = Ezagent.URI.agent(workspace_name, "reusable-#{n}")

    {:ok, _pid} =
      Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{
        uri: agent_uri,
        behaviors: Ezagent.Entity.Agent.base_behaviors()
      })

    :ok = Ezagent.WorkspaceRegistry.bind(agent_uri, workspace_uri)
    :ok = Ezagent.Agent.RecipeAttributes.put(agent_uri, recipe_name)
    on_exit(fn -> terminate(agent_uri) end)
    agent_uri
  end

  defp live_agent(n, recipe_name, %URI{} = workspace_uri, flavor) when is_binary(flavor) do
    agent_uri = live_agent(n, recipe_name, workspace_uri)
    :ok = Ezagent.AgentFlavorAttributes.put(agent_uri, flavor)
    agent_uri
  end

  defp grant_manage(grantee, target) do
    proposed =
      Ezagent.CreatorGrant.manage_cap(
        :agent,
        target,
        Ezagent.Capability.workspace_of(target),
        grantee
      )

    :ok =
      Ezagent.Identity.Grant.grant_cap_via_router(
        grantee,
        proposed,
        {:admin, @owner_uri},
        :sync
      )

    wanted_key = Ezagent.Capability.identity_key(proposed)

    Enum.find(Ezagent.Identity.list_caps_for(grantee), fn cap ->
      Ezagent.Capability.identity_key(cap) == wanted_key
    end)
  end

  defp activate_recipe_binding(agent_uri, recipe_name) do
    {:ok, recipe} =
      RecipeRegistry.lookup(RecipeRegistry.system_workspace_uri(), recipe_name)

    {:ok, proposals} =
      Mix.Tasks.Ezagent.Agent.GrantRecipeCaps.propose_recipe_caps(
        agent_uri,
        recipe,
        [:ezagent, :test, :task_3]
      )

    RecipeCapBinding.issue_and_upsert(agent_uri, recipe_name, @owner_uri, proposals)
  end

  defp with_failure_mode(mode, operation) when is_function(operation, 0) do
    key = {ConvergenceTimeoutTemplate, :failure_mode}
    previous = Process.put(key, mode)

    try do
      operation.()
    after
      case previous do
        nil -> Process.delete(key)
        value -> Process.put(key, value)
      end
    end
  end

  defp assert_fresh_role_rolled_back(planned_uri, config_dir) do
    assert eventually(fn -> KindRegistry.lookup(planned_uri) == :error end)
    assert :not_found = RecipeCapBinding.fetch(planned_uri)
    assert :error = Ezagent.AgentLineage.lookup(planned_uri)
    refute File.exists?(config_dir)
  end

  defp members_of(session_uri) do
    {:ok, pid} = KindRegistry.lookup(session_uri)
    %{state: %{session: %{state: slice}}} = :sys.get_state(pid)
    Map.get(slice, :members, %{})
  end

  defp owner_cap_gated_probe(%URI{} = session_uri) do
    target = Ezagent.URI.with_action(session_uri, :session, :attach)
    {:ok, cap} = Ezagent.Cap.issue_for_action({:admin, @owner_uri}, @owner_uri, target)

    Invocation.dispatch(%Invocation{
      origin: :trusted_internal,
      target: target,
      mode: :call,
      args: %{filename: "owner-usable-probe.txt"},
      ctx: %{
        caller: @owner_uri,
        authenticated_principal: @owner_uri,
        caps: MapSet.new([cap]),
        reply: {:caller_inbox, self()}
      }
    })
  end

  @tag terminate_system_workspace_before_fixture: true
  test "materializes after its ambient system workspace was terminated" do
    n = uniq()
    session_uri = live_session(n)
    recipe_name = seed_recipe(n)
    role_name = "greeter-#{n}"
    flavor = register_stub_flavor(n)

    assert {:ok, _summary} =
             DefinitionAgents.materialize_definition_agents(
               session_uri,
               @workspace_uri,
               @owner_uri,
               [%{recipe: recipe_name, role_name: role_name, flavor: flavor}]
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

    # S6 sole-source I1: create/1 self-stored the exact durable artifact. Full
    # struct equality (including granted_at) proves no post-spawn re-issue
    # silently replaced it with a logically-equal cap.
    assert {:ok, %{caps: bound_caps, version: 1, issuer_uri: @owner_uri}} =
             RecipeCapBinding.fetch(planned)

    bound_cap =
      Enum.find(bound_caps, fn cap ->
        cap.behavior == Ezagent.ActionSet.Identity and cap.action == :list_caps
      end)

    live_cap =
      Enum.find(caps, fn cap ->
        cap.behavior == Ezagent.ActionSet.Identity and cap.action == :list_caps
      end)

    assert %Ezagent.Capability{granted_by: @owner_uri} = bound_cap
    assert live_cap == bound_cap

    assert Enum.count(caps, fn cap ->
             cap.behavior == Ezagent.ActionSet.Identity and cap.action == :list_caps
           end) == 1
  end

  test "grants the session owner Manage authority over a materialized role agent" do
    n = uniq()
    session_uri = live_session(n)
    recipe_name = seed_recipe(n)
    role_name = "pty-owner-#{n}"
    flavor = register_stub_flavor(n)

    assert {:ok, _summary} =
             DefinitionAgents.materialize_definition_agents(
               session_uri,
               @workspace_uri,
               @owner_uri,
               [%{recipe: recipe_name, role_name: role_name, flavor: flavor}]
             )

    agent_uri = SessionBehavior.role_name_to_uri(members_of(session_uri), role_name)
    on_exit(fn -> terminate(agent_uri) end)

    assert eventually(fn ->
             Enum.any?(Ezagent.Identity.list_caps_for(@owner_uri), fn cap ->
               cap.kind == :agent and
                 cap.behavior == Ezagent.ActionSet.Manage and
                 cap.action == :any and
                 Ezagent.URI.stable_key(cap.instance) == Ezagent.URI.stable_key(agent_uri)
             end)
           end)
  end

  test "passive data role stays out of membership and receives an owner-resolvable composition binding" do
    n = uniq()
    session_uri = live_session(n)
    source_recipe = seed_recipe(n)
    data_recipe = seed_passive_recipe(n)
    flavor = register_stub_flavor(n)

    provenance = %{
      install_id: "passive-install-#{n}",
      definition_config_id: "passive-config-#{n}",
      definition_content_hash: "passive-hash-#{n}"
    }

    roles = [
      %{
        recipe: source_recipe,
        role_name: "operator-#{n}",
        flavor: flavor,
        composition_provenance: provenance,
        operates: [
          %{
            role: "data-#{n}",
            behavior: Ezagent.ActionSet.ApiKeys,
            action: :list_api_keys
          }
        ]
      },
      %{
        recipe: data_recipe,
        role_name: "data-#{n}",
        flavor: flavor,
        composition_provenance: provenance,
        operates: []
      }
    ]

    assert {:ok, %{satisfied: satisfied, skipped: []}} =
             DefinitionAgents.materialize_definition_agents(
               session_uri,
               @workspace_uri,
               @owner_uri,
               roles,
               install_authorized?: true
             )

    assert Enum.sort(satisfied) == Enum.sort(["operator-#{n}", "data-#{n}"])

    members = members_of(session_uri)
    source = SessionBehavior.role_name_to_uri(members, "operator-#{n}")
    assert %URI{} = source
    assert SessionBehavior.role_name_to_uri(members, "data-#{n}") == nil

    assert [%CompositionBinding{target_uri: target_uri, status: :active}] =
             CompositionBinding.for_session(session_uri)

    target = Ezagent.URI.new!(target_uri)
    on_exit(fn -> Enum.each([source, target], &terminate/1) end)

    assert {:ok, @owner_uri} = Ezagent.AgentLineage.lookup(target)

    assert Enum.any?(Ezagent.Identity.list_caps_for(source), fn cap ->
             cap.behavior == Ezagent.ActionSet.ApiKeys and cap.action == :list_api_keys and
               cap.instance == target
           end)

    assert {:ok, %{satisfied: satisfied_again, skipped: []}} =
             DefinitionAgents.materialize_definition_agents(
               session_uri,
               @workspace_uri,
               @owner_uri,
               roles,
               install_authorized?: true
             )

    assert Enum.sort(satisfied_again) == Enum.sort(satisfied)

    assert [%CompositionBinding{target_uri: ^target_uri}] =
             CompositionBinding.for_session(session_uri)
  end

  test "a bridge-unavailable ready role converges into the roster before materialization succeeds" do
    n = uniq()
    session_uri = live_session(n)
    recipe_name = seed_recipe_with_behavior(n)
    role_name = "bridge-unavailable-#{n}"
    flavor = register_stub_flavor(n)

    assert {:ok, %{satisfied: [^role_name], skipped: []}} =
             DefinitionAgents.materialize_definition_agents(
               session_uri,
               @workspace_uri,
               @owner_uri,
               [%{recipe: recipe_name, role_name: role_name, flavor: flavor}]
             )

    planned =
      RecipeCapBinding
      |> where([binding], binding.recipe_name == ^recipe_name)
      |> where([binding], is_nil(binding.tombstoned_at))
      |> select([binding], binding.agent_uri)
      |> Repo.one!()
      |> URI.new!()

    on_exit(fn -> terminate(planned) end)

    assert eventually(fn ->
             SessionBehavior.role_name_to_uri(members_of(session_uri), role_name) == planned
           end)

    assert {:ok, session_pid} = KindRegistry.lookup(session_uri)
    assert Process.alive?(session_pid)
    assert Session.owner(session_uri) == {:ok, @owner_uri}
    assert Ezagent.ReadyGate.status(planned) == :ready
    refute Ezagent.Agent.TransportReadiness.transport_joined?(planned)

    assert {:ok, %{ok: true}} = owner_cap_gated_probe(session_uri)

    assert {:ok, %{caps: bound_caps, issuer_uri: @owner_uri}} = RecipeCapBinding.fetch(planned)

    bound_cap =
      Enum.find(bound_caps, fn cap ->
        cap.behavior == MaterializedRoleTestBehavior and cap.action == :ping
      end)

    assert %Ezagent.Capability{granted_by: @owner_uri} = bound_cap
  end

  test "fresh role grants creator Manage before attempting the session join" do
    source =
      "../../lib/ezagent_domain_instance_message/session_creator/definition_agent_lifecycle.ex"
      |> Path.expand(__DIR__)
      |> File.read!()

    assert {grant_index, _} = :binary.match(source, "Ezagent.Workspace.grant_creator_manage_cap")

    assert {join_index, _} =
             :binary.match(source, "join_or_cleanup(session_uri, planned_uri, role_name, recipe)")

    assert grant_index < join_index,
           "the session admission gate must see the creator Manage cap before it evaluates the join"
  end

  test "a fresh role that fails recipe-cap binding leaves no live or durable residue" do
    n = uniq()
    session_uri = live_session(n)
    recipe_name = seed_bind_failure_recipe(n)
    role_name = "bind-failure-#{n}"
    flavor = register_convergence_timeout_flavor(n)

    assert {:error, {:agent_bind_recipe_caps_failed, {:behavior_not_loaded, @missing_behavior}},
            %{satisfied: [], skipped: [%{role_name: ^role_name}]}} =
             with_failure_mode(:bind, fn ->
               DefinitionAgents.materialize_definition_agents(
                 session_uri,
                 @workspace_uri,
                 @owner_uri,
                 [%{recipe: recipe_name, role_name: role_name, flavor: flavor}]
               )
             end)

    assert_receive {:task_3_fresh_spawned, planned_uri, config_dir}
    assert_fresh_role_rolled_back(planned_uri, config_dir)
  end

  test "a provisional post-spawn failure surfaces rollback failure evidence" do
    n = uniq()
    session_uri = live_session(n)
    recipe_name = seed_recipe(n)
    role_name = "provisional-rollback-failure-#{n}"
    flavor = register_convergence_timeout_flavor(n)

    declaration = %{
      recipe: recipe_name,
      role_name: role_name,
      flavor: flavor,
      credential_admission: :before_session_join
    }

    assert {:error,
            {
              _post_spawn_failure,
              {:rollback_failed, {:fresh_spawn_rollback_incomplete, rollback_errors}}
            }} =
             with_failure_mode(:post_spawn_rollback_failure, fn ->
               DefinitionAgents.spawn_provisional(
                 session_uri,
                 @workspace_uri,
                 @owner_uri,
                 declaration
               )
             end)

    assert Enum.any?(rollback_errors, fn
             {:config_dir_destroy_failed, _agent_uri, _path, :injected_config_cleanup_failure} ->
               true

             _ ->
               false
           end)
  end

  test "a fresh role that fails join leaves no live or durable residue" do
    n = uniq()
    session_uri = live_session(n)
    recipe_name = seed_recipe(n)
    role_name = "join-failure-#{n}"
    flavor = register_convergence_timeout_flavor(n)
    blocker = live_agent("join-blocker-#{n}", recipe_name)

    assert {:error, {:agent_join_failed, ^role_name, _reason},
            %{satisfied: [], skipped: [%{role_name: ^role_name}]}} =
             with_failure_mode({:join, session_uri, blocker, role_name}, fn ->
               DefinitionAgents.materialize_definition_agents(
                 session_uri,
                 @workspace_uri,
                 @owner_uri,
                 [%{recipe: recipe_name, role_name: role_name, flavor: flavor}]
               )
             end)

    assert_receive {:task_3_fresh_spawned, planned_uri, config_dir}
    assert_fresh_role_rolled_back(planned_uri, config_dir)
  end

  test "a fresh non-convergent role leaves no live or durable residue" do
    n = uniq()
    session_uri = live_session(n)
    recipe_name = seed_recipe(n)
    role_name = "membership-timeout-#{n}"
    flavor = register_convergence_timeout_flavor(n)

    assert {:error,
            {:agent_membership_convergence_failed, ^role_name, :membership_convergence_timeout},
            %{satisfied: [], skipped: [%{role_name: ^role_name}]}} =
             with_failure_mode(:convergence, fn ->
               DefinitionAgents.materialize_definition_agents(
                 session_uri,
                 @workspace_uri,
                 @owner_uri,
                 [%{recipe: recipe_name, role_name: role_name, flavor: flavor}]
               )
             end)

    assert_receive {:task_3_fresh_spawned, planned_uri, config_dir}
    assert SessionBehavior.role_name_to_uri(members_of(session_uri), role_name) == nil
    assert_fresh_role_rolled_back(planned_uri, config_dir)
  end

  test "retries two fresh roles after a convergence timeout without reusing another session's agents" do
    n = uniq()
    recipe_name = seed_recipe(n)
    flavor = register_convergence_timeout_flavor(n)

    roles = [
      %{recipe: recipe_name, role_name: "front-desk-#{n}", flavor: flavor},
      %{recipe: recipe_name, role_name: "llm-#{n}", flavor: flavor}
    ]

    established_session = live_session("established-#{n}")

    assert {:ok, %{satisfied: established_roles, skipped: []}} =
             DefinitionAgents.materialize_definition_agents(
               established_session,
               @workspace_uri,
               @owner_uri,
               roles
             )

    assert established_roles == Enum.map(roles, & &1.role_name)

    established_member_uris =
      roles
      |> Enum.map(
        &SessionBehavior.role_name_to_uri(members_of(established_session), &1.role_name)
      )
      |> MapSet.new()

    Enum.each(established_member_uris, fn agent_uri ->
      assert_receive {:task_3_fresh_spawned, ^agent_uri, _config_dir}
      on_exit(fn -> terminate(agent_uri) end)
    end)

    retry_session = live_session("retry-#{n}")
    [first_role | _] = roles
    first_role_name = first_role.role_name

    assert {:error,
            {:agent_membership_convergence_failed, ^first_role_name,
             :membership_convergence_timeout},
            %{satisfied: [], skipped: [%{role_name: ^first_role_name}]}} =
             with_failure_mode(:convergence, fn ->
               DefinitionAgents.materialize_definition_agents(
                 retry_session,
                 @workspace_uri,
                 @owner_uri,
                 roles
               )
             end)

    assert_receive {:task_3_fresh_spawned, failed_uri, failed_config_dir}
    assert_fresh_role_rolled_back(failed_uri, failed_config_dir)

    assert {:ok, %{satisfied: retried_roles, skipped: []}} =
             DefinitionAgents.materialize_definition_agents(
               retry_session,
               @workspace_uri,
               @owner_uri,
               roles
             )

    assert retried_roles == Enum.map(roles, & &1.role_name)

    retry_member_uris =
      roles
      |> Enum.map(&SessionBehavior.role_name_to_uri(members_of(retry_session), &1.role_name))
      |> MapSet.new()

    assert MapSet.size(retry_member_uris) == 2
    refute MapSet.member?(retry_member_uris, failed_uri)
    assert MapSet.disjoint?(retry_member_uris, established_member_uris)
  end

  test "I3 full orchestrator lane persists four scoped artifacts and revokes the exact inverse" do
    n = uniq()
    session_uri = live_session(n)
    role_name = "orchestrator"
    flavor = register_stub_flavor(n)
    :ok = ensure_orchestrator_recipe()

    working_copy =
      session_uri
      |> Session.read_template_working_copy()
      |> Map.put(:session_template_uri, Ezagent.URI.template(:system, :session, "default"))
      |> Map.put(:member_declarations, [
        %{fill: :agent, recipe: "orchestrator", role_name: role_name, flavor: flavor}
      ])

    assert {:ok, _} = SessionBehavior.system_set_working_copy(session_uri, working_copy)

    task =
      Task.async(fn ->
        receive do
          :run_install ->
            SessionCreator.install_session_socialware(session_uri, @workspace_uri)
        end
      end)

    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), task.pid)
    send(task.pid, :run_install)

    assert {:ok, {:ok, %{satisfied: [^role_name], skipped: []}}} =
             Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill)

    assert {:ok, orchestrator_uri} = Session.orchestrator_uri(session_uri)
    on_exit(fn -> terminate(orchestrator_uri) end)

    assert {:ok, _orchestrator_pid} = KindRegistry.lookup(orchestrator_uri)
    assert {:ok, session_pid} = KindRegistry.lookup(session_uri)
    assert Process.alive?(session_pid)
    assert Session.owner(session_uri) == {:ok, @owner_uri}
    assert {:ok, %{ok: true}} = owner_cap_gated_probe(session_uri)
    assert Ezagent.ReadyGate.status(orchestrator_uri) == :ready

    stored = Ezagent.Identity.read_entity_caps(orchestrator_uri)
    {membership_caps, delegated_caps} = Enum.split_with(stored, &tier1_membership_cap?/1)
    delegated_cap_identities = Enum.uniq_by(delegated_caps, &Ezagent.Capability.identity_key/1)

    assert [_membership_cap] = membership_caps

    {session_caps, non_session_caps} =
      Enum.split_with(delegated_cap_identities, &(&1.kind == :session))

    {workspace_caps, agent_bootstrap_caps} =
      Enum.split_with(non_session_caps, &(&1.kind == :workspace))

    assert length(session_caps) == expected_orchestrator_session_cap_count()

    assert MapSet.new(Enum.map(workspace_caps, &Ezagent.Capability.action_of/1)) ==
             MapSet.new([
               :list_agent_templates,
               :list_session_templates,
               :write_session_templates
             ])

    # A ready fresh Agent has three sources of non-session/workspace authority:
    # the recipe's declared requests, Identity.create/1's structural self-license,
    # and ConfigEvolve's two post-ready self-heal caps. Derive the recipe portion
    # from the registry so this assertion pins the authority sources without
    # baking in the orchestrator recipe's current tool list.
    {:ok, orchestrator_recipe} =
      RecipeRegistry.lookup(RecipeRegistry.system_workspace_uri(), "orchestrator")

    recipe_cap_pairs =
      MapSet.new(Enum.map(orchestrator_recipe.requested_caps, &{&1.behavior, &1.action}))

    expected_agent_cap_pairs =
      MapSet.union(
        recipe_cap_pairs,
        MapSet.new([
          {Ezagent.ActionSet.Identity, :self_license},
          {Ezagent.ActionSet.ConfigEvolve, :reconcile_cascade},
          {Ezagent.ActionSet.Sandbox, :update_config}
        ])
      )

    assert MapSet.new(
             Enum.map(agent_bootstrap_caps, fn cap ->
               {cap.behavior, Ezagent.Capability.action_of(cap)}
             end)
           ) == expected_agent_cap_pairs

    assert Enum.all?(
             session_caps ++ workspace_caps,
             &concrete_orchestrator_cap?(&1, session_uri, @workspace_uri)
           )

    revoked_scope_caps = session_caps ++ workspace_caps

    refute Enum.any?(
             Ezagent.Identity.read_entity_caps(orchestrator_uri),
             &scoped_orchestrator_cap?/1
           )

    assert Enum.all?(membership_caps, fn expected ->
             Enum.any?(stored, fn held ->
               Ezagent.Capability.identity_key(held) ==
                 Ezagent.Capability.identity_key(expected)
             end)
           end)

    assert :ok =
             Ezagent.Entity.Session.Orchestrator.Caps.revoke_orchestrator_scoped_caps(
               orchestrator_uri,
               session_uri,
               @owner_uri,
               @workspace_uri
             )

    assert eventually(fn ->
             orchestrator_uri
             |> Ezagent.Identity.read_entity_caps()
             |> Enum.any?(fn held ->
               Enum.any?(revoked_scope_caps, fn expected ->
                 Ezagent.Capability.identity_key(held) ==
                   Ezagent.Capability.identity_key(expected)
               end)
             end)
             |> Kernel.not()
           end)
  end

  test "definitive fresh spawn failure creates no cold-target binding" do
    n = uniq()
    session_uri = live_session(n)
    recipe_name = seed_recipe(n)
    role_name = "spawn-fails-#{n}"
    flavor = register_failing_flavor(n)

    assert {:error, {:agent_spawn_failed, ^role_name, _reason}, _partial} =
             DefinitionAgents.materialize_definition_agents(
               session_uri,
               @workspace_uri,
               @owner_uri,
               [%{recipe: recipe_name, role_name: role_name, flavor: flavor}]
             )

    refute RecipeCapBinding
           |> Repo.all()
           |> Enum.any?(&(&1.recipe_name == recipe_name))

    assert SessionBehavior.role_name_to_uri(members_of(session_uri), role_name) == nil
  end

  test "materializes a declared non-cc flavor agent with config, readiness, role, grants, and join" do
    n = uniq()
    session_uri = live_session(n)
    recipe_name = seed_recipe(n)
    role_name = "greeter-non-cc-#{n}"
    flavor = register_stub_flavor(n)

    assert {:ok, _summary} =
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
    assert {:ok, ^recipe_name} = Ezagent.Agent.RecipeAttributes.fetch(planned)

    assert {:ok, sandbox_slice} = Ezagent.Kind.read(planned, :sandbox, spawn: :never)
    sandbox = Ezagent.Kind.normalize_slice_view(sandbox_slice)
    assert Map.has_key?(sandbox, :config_dir_path)

    # the SESSION role_name is on the edge, resolving to the same agent
    assert SessionBehavior.role_name_to_uri(members, role_name) == planned

    caps = Ezagent.Identity.list_caps_for(planned)

    assert Enum.any?(caps, fn cap ->
             cap.behavior == Ezagent.ActionSet.Identity and cap.action == :list_caps
           end)
  end

  test "fresh materialized role member dispatches recipe-declared behavior action" do
    n = uniq()
    session_uri = live_session(n)
    recipe_name = seed_recipe_with_behavior(n)
    role_name = "behavior-member-#{n}"
    flavor = register_stub_flavor(n)

    assert {:ok, _summary} =
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

    assert {:ok, %{pinged: false}} =
             Ezagent.Kind.read(planned, :materialized_role_test, spawn: :never)

    target = Ezagent.URI.with_action(planned, :materialized_role_test, :ping)

    cap =
      Enum.find(Ezagent.Identity.list_caps_for(planned), fn cap ->
        cap.behavior == MaterializedRoleTestBehavior and cap.action == :ping
      end)

    assert %Ezagent.Capability{} = cap

    assert {:ok, %{pong: true}} =
             Ezagent.Router.dispatch(
               Ezagent.Cmd.new(target, :ping, %{}, %{
                 mode: :call,
                 caller: planned,
                 authenticated_principal: planned,
                 caps: MapSet.new([cap]),
                 reply: {:caller_inbox, self()}
               })
             )
  end

  test "orchestrator role materialization does not persist unbound scoped caps" do
    n = uniq()
    session_uri = live_session(n)
    role_name = "orchestrator"
    flavor = register_stub_flavor(n)

    :ok = ensure_orchestrator_recipe()

    assert {:ok, _summary} =
             DefinitionAgents.materialize_definition_agents(
               session_uri,
               @workspace_uri,
               @owner_uri,
               [%{recipe: "orchestrator", role_name: role_name, flavor: flavor}]
             )

    members = members_of(session_uri)
    orchestrator_uri = SessionBehavior.role_name_to_uri(members, role_name)
    on_exit(fn -> terminate(orchestrator_uri) end)

    refute Enum.any?(
             Ezagent.Identity.read_entity_caps(orchestrator_uri),
             &scoped_orchestrator_cap?/1
           )
  end

  test "orchestrator materialization writes the durable :orchestrator_uri binding eagerly (R2)" do
    n = uniq()
    session_uri = live_session(n)
    role_name = "orchestrator"
    flavor = register_stub_flavor(n)

    :ok = ensure_orchestrator_recipe()

    # #1326: `materialize_definition_agents/4` now returns `{:ok, summary}`. The
    # stub flavor is credential-less, so the orchestrator slot is SATISFIED (not
    # skipped) — R2's eager binding write must therefore have run.
    assert {:ok, _summary} =
             DefinitionAgents.materialize_definition_agents(
               session_uri,
               @workspace_uri,
               @owner_uri,
               [%{recipe: "orchestrator", role_name: role_name, flavor: flavor}]
             )

    orchestrator_uri = SessionBehavior.role_name_to_uri(members_of(session_uri), role_name)
    on_exit(fn -> terminate(orchestrator_uri) end)

    # R2/P1 — the durable working copy carries the ACTUAL spawned orchestrator URI
    # and its current materialization epoch, so the orchestrator's MCP tool
    # surface is recoverable after a BEAM restart without serving stale state.
    working_copy = Session.read_template_working_copy(session_uri)

    assert {:ok, %{uri: ^orchestrator_uri, epoch: epoch, status: :active}} =
             Ezagent.Session.OrchestratorBinding.current(working_copy)

    assert is_binary(epoch)

    # …resolvable via the SAME `Ezagent.UriQuery` read `McpServer.rebuild_from_durable`
    # performs after a restart to recover the 7-tool orchestrator surface.
    assert {:ok, ^orchestrator_uri} =
             Ezagent.Entity.Session.Orchestrator.orchestrator_uri(session_uri)

    assert {:ok, manager_pid} = Ezagent.Session.SessionManager.whereis(orchestrator_uri)

    binding = GenServer.call(manager_pid, :binding)
    assert binding.orchestrator_uri == orchestrator_uri
    assert binding.session_uri == session_uri
    assert binding.workspace_uri == @workspace_uri
    assert binding.owner_uri == @owner_uri

    expected_parent_template_uri =
      Map.get(working_copy, :session_template_uri) ||
        Ezagent.URI.template(:system, :session, "default")

    assert binding.parent_template_uri == expected_parent_template_uri
  end

  test "ensure_orchestrator does not adopt a bare credentialled Agent Kind" do
    n = uniq()
    session_uri = live_session(n)

    orchestrator_uri =
      Ezagent.Entity.Session.Orchestrator.planned_orchestrator_uri(session_uri, @workspace_uri)

    :ok = ensure_orchestrator_recipe()

    {:ok, _pid} =
      Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{
        uri: orchestrator_uri,
        behaviors: Ezagent.Entity.Agent.base_behaviors()
      })

    :ok = Ezagent.WorkspaceRegistry.bind(orchestrator_uri, @workspace_uri)
    :ok = Ezagent.AgentLineage.record(orchestrator_uri, @owner_uri)
    :ok = Ezagent.Agent.RecipeAttributes.put(orchestrator_uri, "orchestrator")
    on_exit(fn -> terminate(orchestrator_uri) end)

    assert {:error, {:orchestrator_adoption_failed, _reason}} =
             Ezagent.Entity.Session.Orchestrator.ensure_orchestrator(
               session_uri,
               @workspace_uri,
               @owner_uri
             )

    assert SessionBehavior.role_name_to_uri(members_of(session_uri), "orchestrator") == nil
  end

  test "reuse install choice joins a credential-less existing agent" do
    n = uniq()
    session_uri = live_session(n)
    recipe_name = seed_recipe(n)
    role_name = "reuse-advisor-#{n}"
    flavor = register_stub_flavor(n)
    reusable = live_agent(n, recipe_name, flavor)

    assert {:ok, %{satisfied: [^role_name], skipped: []}} =
             DefinitionAgents.materialize_definition_agents(
               session_uri,
               @workspace_uri,
               @owner_uri,
               [
                 %{
                   recipe: recipe_name,
                   role_name: role_name,
                   flavor: flavor,
                   install_mode: :reuse,
                   reuse_agent_uri: reusable
                 }
               ]
             )

    members = members_of(session_uri)
    assert SessionBehavior.role_name_to_uri(members, role_name) == reusable
  end

  test "reuse revalidation revoked after preflight leaves a durable unfilled role and no fresh receipt" do
    n = uniq()
    workspace_uri = Ezagent.URI.workspace("reuse-race-#{n}")
    ensure_workspace_kind!(workspace_uri)
    on_exit(fn -> terminate(workspace_uri) end)

    operator = confirmed_user(workspace_uri, "reuse-operator")
    session_uri = live_session(n, workspace_uri, operator)
    recipe_name = seed_recipe(n)
    role_name = "reuse-race-#{n}"
    flavor = register_convergence_timeout_flavor(n)
    reusable = live_agent(n, recipe_name, workspace_uri, flavor)
    manage_cap = grant_manage(operator, reusable)

    assert %Ezagent.Capability{} = manage_cap
    assert Ezagent.Identity.Authority.manages?(operator, reusable)

    declaration = %{
      fill: :agent,
      recipe: recipe_name,
      role_name: role_name,
      flavor: flavor,
      install_mode: :reuse,
      reuse_agent_uri: reusable
    }

    # This is the same composition install preflight that SessionInstaller
    # performs before materialization. Revocation below therefore exercises the
    # concrete preflight -> revoke -> install window the final reuse check seals.
    assert :ok =
             Ezagent.Socialware.CompositionCaps.assert_install_authorized(
               session_uri,
               [Map.put(declaration, :operates, [%{role: "unused"}])],
               install_authorized?: true
             )

    working_copy = reuse_working_copy(workspace_uri, n, declaration)

    assert {:ok, _} = SessionBehavior.system_set_working_copy(session_uri, working_copy)

    assert :ok =
             Ezagent.Identity.Grant.revoke_cap_via_router(
               operator,
               manage_cap,
               {:admin, @owner_uri},
               :sync
             )

    assert eventually(fn -> not Ezagent.Identity.Authority.manages?(operator, reusable) end)

    assert {:ok,
            %{
              satisfied: [],
              skipped: [
                %{
                  role_name: ^role_name,
                  reason: {:reuse_agent_revalidation_failed, ^role_name, :unauthorized}
                }
              ]
            }} = SessionCreator.install_session_socialware(session_uri, {workspace_uri, operator})

    assert [%{role_name: ^role_name, reason: :unavailable}] =
             SessionCreator.unfilled_agent_role_slots(session_uri)

    assert SessionBehavior.role_name_to_uri(members_of(session_uri), role_name) == nil
    assert {:ok, _pid} = KindRegistry.lookup(reusable)
    refute_receive {:task_3_fresh_spawned, _uri, _config_dir}, 100
  end

  test "reuse install choice joins the existing agent despite fresh-agent credential admission" do
    n = uniq()
    session_uri = live_session(n)
    recipe_name = seed_recipe(n)
    role_name = "reuse-credentialled-#{n}"
    flavor = register_env_profile_flavor(n)
    reusable = live_agent(n, recipe_name, flavor)

    declaration = %{
      recipe: recipe_name,
      role_name: role_name,
      flavor: flavor,
      provider: "kimi",
      install_mode: :reuse,
      reuse_agent_uri: reusable
    }

    working_copy =
      SessionBehavior.default_template_working_copy()
      |> Map.put(
        :session_template_uri,
        Ezagent.URI.template("system", :session, "reuse-credentialled@revision-#{n}")
      )
      |> Map.put(:member_declarations, [declaration])

    assert {:ok, _} = SessionBehavior.system_set_working_copy(session_uri, working_copy)

    assert {:ok, %{satisfied: [^role_name], skipped: [], deferred: []}} =
             DefinitionAgents.materialize_definition_agents(
               session_uri,
               @workspace_uri,
               @owner_uri,
               [declaration]
             )

    assert SessionBehavior.role_name_to_uri(members_of(session_uri), role_name) == reusable
    assert AgentAdmission.list(session_uri) == []
  end

  test "provisional admission marks only PTY connections for credential bootstrap" do
    for connection <- [:pty, :api_key] do
      n = uniq()
      session_uri = live_session(n)
      recipe_name = seed_recipe(n)
      role_name = "#{connection}-admission-#{n}"
      flavor = register_connection_capture_flavor(n, connection)

      declaration = %{
        recipe: recipe_name,
        role_name: role_name,
        flavor: flavor,
        credential_admission: :before_session_join
      }

      working_copy =
        SessionBehavior.default_template_working_copy()
        |> Map.put(
          :session_template_uri,
          Ezagent.URI.template("system", :session, "#{connection}-admission@revision-#{n}")
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

      assert {:ok, %{status: :authenticating} = admission} =
               AgentAdmission.begin(session_uri, role_name, @owner_uri, caps)

      provisional_uri = Ezagent.URI.new!(admission.provisional_agent_uri)
      assert SessionBehavior.role_name_to_uri(members_of(session_uri), role_name) == nil

      on_exit(fn ->
        AgentAdmission.cancel(
          session_uri,
          role_name,
          admission.attempt_id,
          {@owner_uri, caps}
        )
      end)

      assert Ezagent.Kind.alive?(provisional_uri)
    end
  end

  test "reuse recipe drift leaves a durable unfilled role" do
    n = uniq()
    session_uri = live_session(n)
    recipe_name = seed_recipe(n)
    other_recipe = seed_recipe("other-#{n}")
    role_name = "reuse-mismatch-#{n}"
    flavor = register_stub_flavor(n)
    reusable = live_agent(n, other_recipe, flavor)

    declaration = %{
      fill: :agent,
      recipe: recipe_name,
      role_name: role_name,
      flavor: flavor,
      install_mode: :reuse,
      reuse_agent_uri: reusable
    }

    assert {:ok, _} =
             SessionBehavior.system_set_working_copy(
               session_uri,
               reuse_working_copy(@workspace_uri, n, declaration)
             )

    assert {:ok, %{satisfied: [], skipped: [%{role_name: ^role_name, reason: reason}]}} =
             SessionCreator.install_session_socialware(session_uri, {@workspace_uri, @owner_uri})

    assert {:reuse_agent_revalidation_failed, ^role_name, :recipe_mismatch} = reason

    assert [%{role_name: ^role_name, reason: :unavailable}] =
             SessionCreator.unfilled_agent_role_slots(session_uri)

    refute Map.has_key?(members_of(session_uri), reusable)
  end

  test "reuse flavor drift leaves a durable unfilled role" do
    n = uniq()
    session_uri = live_session(n)
    recipe_name = seed_recipe(n)
    role_name = "reuse-flavor-mismatch-#{n}"
    declared_flavor = register_stub_flavor(n)
    reusable = live_agent(n, recipe_name, "different-#{declared_flavor}")

    declaration = %{
      fill: :agent,
      recipe: recipe_name,
      role_name: role_name,
      flavor: declared_flavor,
      install_mode: :reuse,
      reuse_agent_uri: reusable
    }

    assert {:ok, _} =
             SessionBehavior.system_set_working_copy(
               session_uri,
               reuse_working_copy(@workspace_uri, n, declaration)
             )

    assert {:ok, %{satisfied: [], skipped: [%{role_name: ^role_name, reason: reason}]}} =
             SessionCreator.install_session_socialware(session_uri, {@workspace_uri, @owner_uri})

    assert {:reuse_agent_revalidation_failed, ^role_name, :flavor_mismatch} = reason

    assert [%{role_name: ^role_name, reason: :unavailable}] =
             SessionCreator.unfilled_agent_role_slots(session_uri)

    refute Map.has_key?(members_of(session_uri), reusable)
  end

  test "reuse join failure preserves the existing process and active recipe binding" do
    n = uniq()
    session_uri = live_session(n)
    recipe_name = seed_recipe(n)
    role_name = "reuse-pending-#{n}"
    flavor = register_stub_flavor(n)
    reusable = live_agent("pending-#{n}", recipe_name, flavor)
    {:ok, reusable_pid} = KindRegistry.lookup(reusable)
    {:ok, active_binding} = activate_recipe_binding(reusable, recipe_name)
    :ok = Ezagent.AgentPassiveAttributes.put(reusable, true)

    assert {:error, {:passive_actor_cannot_join, ^reusable},
            %{satisfied: [], skipped: [%{role_name: ^role_name}]}} =
             DefinitionAgents.materialize_definition_agents(
               session_uri,
               @workspace_uri,
               @owner_uri,
               [
                 %{
                   recipe: recipe_name,
                   role_name: role_name,
                   flavor: flavor,
                   install_mode: :reuse,
                   reuse_agent_uri: reusable
                 }
               ]
             )

    assert {:ok, ^reusable_pid} = KindRegistry.lookup(reusable)
    assert Process.alive?(reusable_pid)
    assert {:ok, ^active_binding} = RecipeCapBinding.fetch(reusable)
  end

  test "idempotent re-materialize (repair/restart) does not error or double-join" do
    n = uniq()
    session_uri = live_session(n)
    recipe_name = seed_recipe(n)
    role_name = "greeter-#{n}"
    flavor = register_stub_flavor(n)
    agents = [%{recipe: recipe_name, role_name: role_name, flavor: flavor}]

    assert {:ok, _summary} =
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
    assert {:ok, _summary} =
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
    flavor = register_stub_flavor(n)

    assert {:error, {:duplicate_agent_role_name, ^role_name}} =
             DefinitionAgents.materialize_definition_agents(
               session_uri,
               @workspace_uri,
               @owner_uri,
               [
                 %{recipe: recipe_name, role_name: role_name, flavor: flavor},
                 %{recipe: recipe_name, role_name: role_name, flavor: flavor}
               ]
             )
  end

  test "fails closed on an unknown recipe (never a cap-less spawn)" do
    n = uniq()
    session_uri = live_session(n)
    missing = "no-such-recipe-#{n}"

    assert {:error, {:unknown_agent_recipe, ^missing}, _partial} =
             DefinitionAgents.materialize_definition_agents(
               session_uri,
               @workspace_uri,
               @owner_uri,
               [%{recipe: missing, role_name: "ghost-#{n}"}]
             )
  end

  test "a credentialless env-backed role materializes with its co-declared role" do
    n = uniq()
    session_uri = live_session(n)
    recipe_name = seed_recipe(n)
    missing_flavor = register_deepseek_missing_flavor(n)
    ok_flavor = register_stub_flavor(n)

    cred_missing_role = "env-cred-#{n}"
    ok_role = "ok-role-#{n}"

    assert {:ok, summary} =
             DefinitionAgents.materialize_definition_agents(
               session_uri,
               @workspace_uri,
               @owner_uri,
               [
                 %{recipe: recipe_name, role_name: cred_missing_role, flavor: missing_flavor},
                 %{recipe: recipe_name, role_name: ok_role, flavor: ok_flavor}
               ]
             )

    assert summary.skipped == []
    assert summary.satisfied == [cred_missing_role, ok_role]

    members = members_of(session_uri)
    assert %URI{} = SessionBehavior.role_name_to_uri(members, cred_missing_role)
    assert %URI{} = SessionBehavior.role_name_to_uri(members, ok_role)
  end

  test "a credential role's provider is preserved through mandatory admission" do
    n = uniq()
    session_uri = live_session(n)
    recipe_name = seed_recipe(n)
    env_flavor = register_env_profile_flavor(n)

    previous = System.get_env("MOONSHOT_API_KEY")
    System.delete_env("MOONSHOT_API_KEY")

    on_exit(fn ->
      if previous,
        do: System.put_env("MOONSHOT_API_KEY", previous),
        else: System.delete_env("MOONSHOT_API_KEY")
    end)

    role = "kimi-role-#{n}"

    declaration = %{
      "provider" => "kimi",
      recipe: recipe_name,
      role_name: role,
      flavor: env_flavor
    }

    working_copy =
      SessionBehavior.default_template_working_copy()
      |> Map.put(
        :session_template_uri,
        Ezagent.URI.template("system", :session, "provider-admission@revision-#{n}")
      )
      |> Map.put(:member_declarations, [declaration])

    assert {:ok, _} = SessionBehavior.system_set_working_copy(session_uri, working_copy)

    assert {:ok, summary} =
             DefinitionAgents.materialize_definition_agents(
               session_uri,
               @workspace_uri,
               @owner_uri,
               [declaration]
             )

    assert summary.skipped == []
    assert summary.satisfied == []
    assert summary.deferred == [role]

    assert [%{role_name: ^role, status: :pending_auth, provider: "kimi"}] =
             AgentAdmission.list(session_uri)

    caps = Ezagent.Identity.list_caps_for(@owner_uri)
    assert {:ok, authenticating} = AgentAdmission.begin(session_uri, role, @owner_uri, caps)
    System.put_env("MOONSHOT_API_KEY", "test-only-key")

    assert {:ok, %{status: :joined, provider: "kimi"}} =
             AgentAdmission.complete(
               session_uri,
               role,
               authenticating.attempt_id,
               {@owner_uri, caps}
             )

    assert %URI{} = member = SessionBehavior.role_name_to_uri(members_of(session_uri), role)
    on_exit(fn -> terminate(member) end)
  end

  test "a gated role with no credential source is deferred instead of skipped" do
    n = uniq()
    session_uri = live_session(n)
    recipe_name = seed_recipe(n)
    env_flavor = register_env_profile_flavor(n)
    role_name = "gated-kimi-#{n}"

    previous = System.get_env("MOONSHOT_API_KEY")
    System.delete_env("MOONSHOT_API_KEY")

    on_exit(fn ->
      if previous,
        do: System.put_env("MOONSHOT_API_KEY", previous),
        else: System.delete_env("MOONSHOT_API_KEY")
    end)

    declaration = %{
      role_name: role_name,
      fill: :agent,
      recipe: recipe_name,
      flavor: env_flavor,
      provider: "kimi",
      credential_admission: :before_session_join
    }

    working_copy =
      SessionBehavior.default_template_working_copy()
      |> Map.put(
        :session_template_uri,
        Ezagent.URI.template("system", :session, "gated@revision-#{n}")
      )
      |> Map.put(:member_declarations, [declaration])

    assert {:ok, _} = SessionBehavior.system_set_working_copy(session_uri, working_copy)

    assert {:ok, %{satisfied: [], skipped: [], deferred: [^role_name]}} =
             DefinitionAgents.materialize_definition_agents(
               session_uri,
               @workspace_uri,
               @owner_uri,
               [declaration]
             )

    assert SessionBehavior.role_name_to_uri(members_of(session_uri), role_name) == nil

    assert [
             %{
               role_name: ^role_name,
               status: :pending_auth,
               connection: {:api_key, %{provider: "moonshot", label: "Configure test API key"}}
             }
           ] =
             EzagentDomainInstanceMessage.SessionCreator.AgentAdmission.list(session_uri)
  end

  test "the production sweep invalidates a joined profile-driven API-key admission" do
    n = uniq()
    session_uri = live_session(n)
    recipe_name = seed_recipe(n)
    env_flavor = register_env_profile_flavor(n)
    role_name = "gated-kimi-revalidation-#{n}"
    previous = System.get_env("MOONSHOT_API_KEY")

    on_exit(fn ->
      if previous,
        do: System.put_env("MOONSHOT_API_KEY", previous),
        else: System.delete_env("MOONSHOT_API_KEY")
    end)

    declaration = %{
      role_name: role_name,
      fill: :agent,
      recipe: recipe_name,
      flavor: env_flavor,
      provider: "kimi",
      credential_admission: :before_session_join
    }

    working_copy =
      SessionBehavior.default_template_working_copy()
      |> Map.put(
        :session_template_uri,
        Ezagent.URI.template("system", :session, "gated-revalidation@revision-#{n}")
      )
      |> Map.put(:member_declarations, [declaration])

    assert {:ok, _} = SessionBehavior.system_set_working_copy(session_uri, working_copy)
    System.delete_env("MOONSHOT_API_KEY")

    assert {:ok, %{deferred: [^role_name]}} =
             DefinitionAgents.materialize_definition_agents(
               session_uri,
               @workspace_uri,
               @owner_uri,
               [declaration]
             )

    caps = Ezagent.Identity.list_caps_for(@owner_uri)
    assert {:ok, authenticating} = AgentAdmission.begin(session_uri, role_name, @owner_uri, caps)
    System.put_env("MOONSHOT_API_KEY", "test-moonshot-key")

    assert {:ok, %{status: :joined, provider: "kimi"} = joined} =
             AgentAdmission.complete(
               session_uri,
               role_name,
               authenticating.attempt_id,
               {@owner_uri, caps}
             )

    legacy = Map.delete(joined, :provider)
    assert :ok = AgentAdmissionState.put_admission(session_uri, legacy)

    assert {:ok, %{status: :joined, provider: "kimi"}} =
             AgentAdmission.current(session_uri, declaration)

    assert [%{provider: "kimi"}] = AgentAdmission.list(session_uri)

    assert :ok =
             AgentAdmissionState.put_admission(
               session_uri,
               AgentAdmission.list(session_uri) |> hd() |> Map.delete(:provider)
             )

    System.delete_env("MOONSHOT_API_KEY")
    _results = AgentAdmissionSweeper.run_due(DateTime.utc_now())

    assert [
             %{
               role_name: ^role_name,
               status: :pending_auth,
               provider: "kimi",
               attempt_id: nil,
               provisional_agent_uri: nil,
               failure_code: :authentication_failed
             }
           ] = AgentAdmission.list(session_uri)
  end

  test "an env-credential flavor without a provider still requires admission" do
    n = uniq()
    session_uri = live_session(n)
    recipe_name = seed_recipe(n)
    env_flavor = register_env_profile_flavor(n)
    role = "no-profile-#{n}"
    declaration = %{recipe: recipe_name, role_name: role, flavor: env_flavor}

    working_copy =
      SessionBehavior.default_template_working_copy()
      |> Map.put(
        :session_template_uri,
        Ezagent.URI.template("system", :session, "no-profile@revision-#{n}")
      )
      |> Map.put(:member_declarations, [declaration])

    assert {:ok, _} = SessionBehavior.system_set_working_copy(session_uri, working_copy)

    assert {:ok, summary} =
             DefinitionAgents.materialize_definition_agents(
               session_uri,
               @workspace_uri,
               @owner_uri,
               [declaration]
             )

    assert summary.skipped == []
    assert summary.satisfied == []
    assert summary.deferred == [role]

    assert [%{role_name: ^role, status: :pending_auth, provider: nil}] =
             AgentAdmission.list(session_uri)

    assert SessionBehavior.role_name_to_uri(members_of(session_uri), role) == nil
  end

  test "a credentialless slice-backed role materializes with its co-declared role" do
    n = uniq()
    session_uri = live_session(n)
    recipe_name = seed_recipe(n)
    slice_flavor = register_slice_stub_flavor(n)
    ok_flavor = register_stub_flavor(n)

    cred_role = "slice-cred-#{n}"
    ok_role = "ok-role-#{n}"

    assert {:ok, summary} =
             DefinitionAgents.materialize_definition_agents(
               session_uri,
               @workspace_uri,
               @owner_uri,
               [
                 %{recipe: recipe_name, role_name: cred_role, flavor: slice_flavor},
                 %{recipe: recipe_name, role_name: ok_role, flavor: ok_flavor}
               ]
             )

    assert summary.skipped == []
    assert summary.satisfied == [cred_role, ok_role]

    members = members_of(session_uri)
    assert %URI{} = SessionBehavior.role_name_to_uri(members, cred_role)
    assert %URI{} = SessionBehavior.role_name_to_uri(members, ok_role)
  end

  # #185 — the SAME slice-backed flavor with the recipe's `credential_optional`
  # declaration (the hello.llm shape) is NOT pre-skipped: it spawns keyless and
  # joins — the credential may still arrive via the cascade at cold spawn.
  test "a credential_optional slice-credential role is not pre-skipped (keyless join)" do
    n = uniq()
    session_uri = live_session(n)
    recipe_name = seed_recipe_with_config(n, %{credential_optional: true})
    slice_flavor = register_slice_stub_flavor(n)
    role_name = "slice-optional-#{n}"

    assert {:ok, summary} =
             DefinitionAgents.materialize_definition_agents(
               session_uri,
               @workspace_uri,
               @owner_uri,
               [%{recipe: recipe_name, role_name: role_name, flavor: slice_flavor}]
             )

    assert summary.skipped == []
    assert summary.satisfied == [role_name]

    members = members_of(session_uri)
    assert %URI{} = member = SessionBehavior.role_name_to_uri(members, role_name)
    on_exit(fn -> terminate(member) end)
  end

  defp scoped_orchestrator_cap?(%Ezagent.Capability{} = cap) do
    scope_cap? =
      cap.kind in [:session, :agent] and cap.behavior == :any and
        Ezagent.Capability.action_of(cap) == :any and
        match?({scope, %URI{}} when scope in [:within_session, :spawned_by], cap.instance)

    template_cap? =
      cap.kind in [:session_template, :agent_template] and
        cap.behavior == Ezagent.ActionSet.Template and
        Ezagent.Capability.action_of(cap) == :any and
        match?({:within_workspace, %URI{}}, cap.instance)

    scope_cap? or template_cap?
  end

  defp tier1_membership_cap?(%Ezagent.Capability{} = cap) do
    cap.kind == :session and cap.behavior == Ezagent.ActionSet.Session and
      Ezagent.Capability.action_of(cap) == :receive and
      Ezagent.Capability.granted_by_entity?(cap)
  end

  defp tier1_membership_cap?(_cap), do: false

  defp concrete_orchestrator_cap?(cap, session_uri, workspace_uri) do
    cap.instance in [session_uri, workspace_uri] and
      cap.workspace_uri == workspace_uri and is_binary(cap.signature) and
      is_binary(cap.key_id) and match?(%URI{}, cap.grantee_uri)
  end

  defp expected_orchestrator_session_cap_count do
    Ezagent.CapabilityRegistry.subjects_for_kind(Ezagent.Entity.Session)
    |> Enum.reject(&Ezagent.Cap.Verifier.non_cap_action?(&1.behavior, &1.action))
    |> Enum.reject(&(&1.behavior == Ezagent.ActionSet.Session and &1.action == :receive))
    |> length()
  end

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
