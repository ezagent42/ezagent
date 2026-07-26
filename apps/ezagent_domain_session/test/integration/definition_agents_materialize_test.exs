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
  alias Ezagent.Cap.Delivery
  alias Ezagent.Socialware.CompositionBinding
  alias Ezagent.{Invocation, KindRegistry}
  alias EzagentCore.Repo
  alias EzagentDomainInstanceMessage.MaterializedRoleTestBehavior
  alias EzagentDomainInstanceMessage.SessionCreator
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

  defmodule NeverReadyTemplate do
    @moduledoc false
    @behaviour Ezagent.Kind.Template

    @impl Ezagent.Kind.Template
    def template_name, do: "definition_agents.never_ready"

    @impl Ezagent.Kind.Template
    def validate(%{
          "class" => "definition_agents.never_ready",
          "agent_uri" => agent_uri,
          "cwd" => cwd
        })
        when is_binary(agent_uri) and is_binary(cwd),
        do: :ok

    def validate(_), do: {:error, :invalid_definition_agents_never_ready_template}

    @impl Ezagent.Kind.Template
    def instantiate(_name, data, _workspace_uri) do
      uri = Ezagent.URI.new!(data["agent_uri"])

      case Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{
             uri: uri,
             behaviors: Ezagent.Entity.Agent.base_behaviors(),
             role: data["role"]
           }) do
        {:ok, _pid} ->
          :ok = Ezagent.ReadyGate.put(uri, :not_ready)
          {:ok, [uri], %{fresh?: true, config_dir_path: nil}}

        {:error, {:already_started, _pid}} ->
          {:ok, [uri], %{fresh?: false}}

        {:error, {:already_registered, _}} ->
          {:ok, [uri], %{fresh?: false}}

        {:error, reason} ->
          {:error, reason}
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

  defp register_never_ready_flavor(n) do
    flavor = "definition_agents_never_ready_#{n}"

    :ok =
      Ezagent.AgentFlavorRegistry.register(%{
        flavor: flavor,
        kind: Ezagent.Entity.Agent,
        template_class: NeverReadyTemplate
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
      Ezagent.Kind.spawn(Session, %{
        uri: session_uri,
        behaviors: Session.behaviors(),
        owner_uri: @owner_uri
      })

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

  test "I3 install lane returns while a role agent never readies and keeps the session usable" do
    n = uniq()
    session_uri = live_session(n)
    recipe_name = seed_recipe_with_behavior(n)
    role_name = "never-ready-#{n}"
    flavor = register_never_ready_flavor(n)

    working_copy =
      session_uri
      |> Session.read_template_working_copy()
      |> Map.put(:session_template_uri, Ezagent.URI.template(:system, :session, "default"))
      |> Map.put(:member_declarations, [
        %{fill: :agent, recipe: recipe_name, role_name: role_name, flavor: flavor}
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

    assert {:ok, result} = Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill)

    assert {:ok, %{satisfied: [^role_name], skipped: []}} = result

    planned =
      RecipeCapBinding
      |> where([binding], binding.recipe_name == ^recipe_name)
      |> where([binding], is_nil(binding.tombstoned_at))
      |> select([binding], binding.agent_uri)
      |> Repo.one!()
      |> URI.new!()

    on_exit(fn -> terminate(planned) end)

    # A never-ready agent cannot absorb its tier-1 member cap, so cap-as-truth
    # correctly keeps it out of the roster until readiness drains the delivery.
    assert SessionBehavior.role_name_to_uri(members_of(session_uri), role_name) == nil

    assert {:ok, session_pid} = KindRegistry.lookup(session_uri)
    assert Process.alive?(session_pid)
    assert Session.owner(session_uri) == {:ok, @owner_uri}
    assert Ezagent.ReadyGate.status(planned) == :not_ready

    assert {:ok, %{ok: true}} = owner_cap_gated_probe(session_uri)

    assert {:ok, %{caps: bound_caps, issuer_uri: @owner_uri}} = RecipeCapBinding.fetch(planned)

    bound_cap =
      Enum.find(bound_caps, fn cap ->
        cap.behavior == MaterializedRoleTestBehavior and cap.action == :ping
      end)

    assert %Ezagent.Capability{granted_by: @owner_uri} = bound_cap
  end

  test "I3 full orchestrator lane persists four scoped artifacts, stays nonblocking, and revokes the exact inverse" do
    n = uniq()
    session_uri = live_session(n)
    role_name = "orchestrator"
    flavor = register_never_ready_flavor(n)
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

    assert {:ok, orchestrator_pid} = KindRegistry.lookup(orchestrator_uri)
    assert {:ok, session_pid} = KindRegistry.lookup(session_uri)
    assert Process.alive?(session_pid)
    assert Session.owner(session_uri) == {:ok, @owner_uri}
    assert {:ok, %{ok: true}} = owner_cap_gated_probe(session_uri)
    assert Ezagent.ReadyGate.status(orchestrator_uri) == :not_ready

    pending = pending_absorb_artifacts(orchestrator_uri)
    {membership_caps, delegated_caps} = Enum.split_with(pending, &tier1_membership_cap?/1)
    delegated_cap_identities = Enum.uniq_by(delegated_caps, &Ezagent.Capability.identity_key/1)

    assert [_membership_cap] = membership_caps
    # Tier-2 participation settlement can race the full orchestrator handoff
    # and enqueue duplicate :send/:leave artifacts while the never-ready target
    # is buffering. Cap identity is the authority unit; the self-store and the
    # rollback inverse are idempotent by that identity.

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

    # The two agent-bootstrap self-caps (ConfigEvolve.reconcile_cascade +
    # Sandbox.update_config) are the orchestrator's OWN caps, issued during its
    # config-evolve boot reconcile. Whether they are still buffered (:pending) or
    # already self-absorbed (:applied) depends on the transient :ready drain window
    # during the orchestrator's own boot — a machine-timing race (fast CI buffers;
    # a slow host absorbs). Assert the timing-independent invariant: the
    # orchestrator HOLDS them either way (pending ∪ read_entity_caps). An empty
    # union still fails (no masking); and since this is a superset of `pending`, it
    # can only pass where the pending-only assertion passed, never less.
    held_bootstrap_caps =
      orchestrator_uri
      |> Ezagent.Identity.read_entity_caps()
      |> Enum.filter(
        &(&1.behavior in [Ezagent.ActionSet.ConfigEvolve, Ezagent.ActionSet.Sandbox])
      )

    assert MapSet.new(
             Enum.map(agent_bootstrap_caps ++ held_bootstrap_caps, fn cap ->
               {cap.behavior, Ezagent.Capability.action_of(cap)}
             end)
           ) ==
             MapSet.new([
               {Ezagent.ActionSet.ConfigEvolve, :reconcile_cascade},
               {Ezagent.ActionSet.Sandbox, :update_config}
             ])

    assert Enum.all?(
             session_caps ++ workspace_caps,
             &concrete_orchestrator_cap?(&1, session_uri, @workspace_uri)
           )

    revoked_scope_caps = session_caps ++ workspace_caps

    refute Enum.any?(
             Ezagent.Identity.read_entity_caps(orchestrator_uri),
             &scoped_orchestrator_cap?/1
           )

    assert :ready =
             Ezagent.Kind.ReadyTransition.drain_pending_then_mark_ready(
               URI.to_string(orchestrator_uri),
               orchestrator_pid
             )

    stored = Ezagent.Identity.read_entity_caps(orchestrator_uri)

    assert Enum.all?(pending, fn expected ->
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

    # V5 A1b: the tests-only `handle_call(:binding)` introspection was DROPPED
    # with the resolver-seam migration — the executor's liveness is probed
    # through the kept `whereis/1` (alive?-filtered); its binding is exercised
    # behaviorally by the tool calls in the sibling tests.
    assert {:ok, manager_pid} = Ezagent.Session.SessionManager.whereis(orchestrator_uri)
    assert is_pid(manager_pid)
  end

  test "ensure_orchestrator skips a bare Agent Kind without credentials (chain C)" do
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

    # Chain C: the bare Agent Kind spawned above has no credential source and no
    # materialized config home, so the reuse path skips it. `ensure_orchestrator`
    # correctly reports the adoption failure.
    assert {:error, {:orchestrator_adoption_failed, :member_not_joined}} =
             Ezagent.Entity.Session.Orchestrator.ensure_orchestrator(
               session_uri,
               @workspace_uri,
               @owner_uri
             )
  end

  test "reuse install choice skips a credential-less agent (chain C) instead of joining a zombie" do
    n = uniq()
    session_uri = live_session(n)
    recipe_name = seed_recipe(n)
    role_name = "reuse-advisor-#{n}"
    reusable = live_agent(n, recipe_name)

    # Chain C: a bare-bones Agent Kind spawned for testing has no credential
    # source and no materialized config home. Before the fix it was reused
    # silently; now it's skipped.
    assert {:ok,
            %{
              satisfied: [],
              skipped: [
                %{role_name: ^role_name, reason: {:config_home_without_credentials, "cc"}}
              ]
            }} =
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
    assert SessionBehavior.role_name_to_uri(members, role_name) == nil
  end

  test "reuse install choice rejects an agent from a different recipe" do
    n = uniq()
    session_uri = live_session(n)
    recipe_name = seed_recipe(n)
    other_recipe = seed_recipe("other-#{n}")
    role_name = "reuse-mismatch-#{n}"
    reusable = live_agent(n, other_recipe)

    assert {:error, {:reuse_agent_recipe_mismatch, ^role_name, ^reusable}, _partial} =
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

  # Regression (WorldConversationTest PR-6 / O-1 flake): a role whose spawn fails
  # with a MISSING-CREDENTIAL reason (`{:backend_api_key_missing, _, _}`, the
  # keyless-CI
  # condition for the cc-custom orchestrator) must be classified as a SKIP, not
  # a hard error — so the batch CONTINUES and a co-declared credential-less role
  # (the py helper) still materializes. Pre-fix, the credential-missing role
  # returned `{:agent_spawn_failed, …}` → the `reduce_while` HALTED with an
  # unhandled 3-tuple → the following role was never materialized AND the install
  # transaction CRASHED with `CaseClauseError`. Ordered credential-missing FIRST
  # so the "batch continues" guarantee is what's under test.
  test "a missing-credential (env-var) spawn failure skips the role and the batch continues" do
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

    # The credential-missing role is SKIPPED (not a hard error) with the
    # `:no_credential_source` reason the durable `unfilled_agent_role_slots`
    # record renders.
    assert [%{role_name: ^cred_missing_role, reason: {:no_credential_source, ^missing_flavor}}] =
             summary.skipped

    # The batch CONTINUED: the role declared AFTER the skipped one materialized
    # and joined as a live member (the exact "py never materialized" bug).
    assert summary.satisfied == [ok_role]

    members = members_of(session_uri)
    assert %URI{} = SessionBehavior.role_name_to_uri(members, ok_role)
    assert SessionBehavior.role_name_to_uri(members, cred_missing_role) == nil
  end

  test "a role slot's provider threads into the credential precondition (the cc-custom seam)" do
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

    # Profile key UNSET: the selected profile's credential is unavailable → the
    # slot is skipped loudly (never a silent zombie), with the
    # `:credential_unavailable` reason from the environment branch.
    assert {:ok, summary} =
             DefinitionAgents.materialize_definition_agents(
               session_uri,
               @workspace_uri,
               @owner_uri,
               [
                 %{
                   "provider" => "kimi",
                   recipe: recipe_name,
                   role_name: role,
                   flavor: env_flavor
                 }
               ]
             )

    assert [%{role_name: ^role, reason: {:credential_unavailable, ^env_flavor}}] =
             summary.skipped

    assert summary.satisfied == []

    # Profile key SET: the SAME slot materializes and joins — the provider was
    # threaded, not hardcoded.
    System.put_env("MOONSHOT_API_KEY", "test-only-key")

    assert {:ok, summary2} =
             DefinitionAgents.materialize_definition_agents(
               session_uri,
               @workspace_uri,
               @owner_uri,
               [
                 %{
                   "provider" => "kimi",
                   recipe: recipe_name,
                   role_name: role,
                   flavor: env_flavor
                 }
               ]
             )

    assert summary2.skipped == []
    assert summary2.satisfied == [role]

    members = members_of(session_uri)
    assert %URI{} = member = SessionBehavior.role_name_to_uri(members, role)
    on_exit(fn -> terminate(member) end)
  end

  test "a role slot with NO provider on an env-credential flavor fails closed (skip)" do
    n = uniq()
    session_uri = live_session(n)
    recipe_name = seed_recipe(n)
    env_flavor = register_env_profile_flavor(n)
    role = "no-profile-#{n}"

    assert {:ok, summary} =
             DefinitionAgents.materialize_definition_agents(
               session_uri,
               @workspace_uri,
               @owner_uri,
               [%{recipe: recipe_name, role_name: role, flavor: env_flavor}]
             )

    assert [%{role_name: ^role, reason: {:credential_unavailable, ^env_flavor}}] =
             summary.skipped

    assert summary.satisfied == []
  end

  # #185 — a SLICE-backed (curl-style) flavor whose recipe marks the credential
  # REQUIRED must fail LOUD at provisioning: the slot is skipped with the
  # `:no_credential_source` reason (the durable `unfilled_agent_role_slots`
  # record renders it), the batch CONTINUES, and no keyless agent ever joins.
  # Pre-#185 the precondition waved slice flavors through, the cascade's
  # `:no_credential_source` surfaced at spawn as a hard `{:agent_spawn_failed,
  # …}`, and the whole batch halted — a co-declared credential-less role was
  # never materialized.
  test "a required slice-credential role with no source is skipped loud and the batch continues" do
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

    assert [%{role_name: ^cred_role, reason: {:no_credential_source, ^slice_flavor}}] =
             summary.skipped

    # The batch CONTINUED: the role declared AFTER the skipped one materialized
    # and joined as a live member.
    assert summary.satisfied == [ok_role]

    members = members_of(session_uri)
    assert %URI{} = SessionBehavior.role_name_to_uri(members, ok_role)
    assert SessionBehavior.role_name_to_uri(members, cred_role) == nil
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

  defp pending_absorb_artifacts(uri) do
    from(delivery in Delivery,
      where: delivery.target_uri == ^URI.to_string(uri),
      where: delivery.op == :absorb_cap,
      where: delivery.status == :pending,
      order_by: [asc: delivery.id],
      select: delivery.payload
    )
    |> Repo.all()
    |> Enum.map(fn payload ->
      %{op: :absorb_cap, cap: artifact} = :erlang.binary_to_term(payload, [:safe])

      artifact
    end)
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
