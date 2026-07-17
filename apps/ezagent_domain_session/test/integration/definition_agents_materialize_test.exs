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
  # `{:backend_api_key_missing, profile, uri}`. Mirrors the real cc-deepseek
  # orchestrator in a keyless env (every CI without the key).
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
    Invocation.dispatch(%Invocation{
      target: Ezagent.URI.with_action(session_uri, :session, :attach),
      mode: :call,
      args: %{filename: "owner-usable-probe.txt"},
      ctx: %{
        caller: @owner_uri,
        caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()]),
        reply: {:caller_inbox, self()}
      }
    })
  end

  test "materializes a declared agent as a member with its role_name + recipe caps" do
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

    members = members_of(session_uri)
    planned = SessionBehavior.role_name_to_uri(members, role_name)
    on_exit(fn -> terminate(planned) end)

    assert {:ok, session_pid} = KindRegistry.lookup(session_uri)
    assert Process.alive?(session_pid)
    assert Session.owner(session_uri) == {:ok, @owner_uri}
    assert Ezagent.ReadyGate.status(planned) == :not_ready

    assert {:ok, %{ok: true}} = owner_cap_gated_probe(session_uri)

    assert {:ok, identity_slice} = Ezagent.Kind.get_slice(planned, :identity)
    caps = identity_slice |> Ezagent.Kind.normalize_slice_view() |> Map.fetch!(:caps)

    assert {:ok, %{caps: bound_caps, issuer_uri: @owner_uri}} = RecipeCapBinding.fetch(planned)

    bound_cap =
      Enum.find(bound_caps, fn cap ->
        cap.behavior == MaterializedRoleTestBehavior and cap.action == :ping
      end)

    assert %Ezagent.Capability{granted_by: @owner_uri} = bound_cap
    assert Enum.member?(caps, bound_cap)
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

    members = members_of(session_uri)
    orchestrator_uri = SessionBehavior.role_name_to_uri(members, role_name)
    on_exit(fn -> terminate(orchestrator_uri) end)

    assert {:ok, orchestrator_pid} = KindRegistry.lookup(orchestrator_uri)
    assert {:ok, session_pid} = KindRegistry.lookup(session_uri)
    assert Process.alive?(session_pid)
    assert Session.owner(session_uri) == {:ok, @owner_uri}
    assert {:ok, %{ok: true}} = owner_cap_gated_probe(session_uri)
    assert Ezagent.ReadyGate.status(orchestrator_uri) == :not_ready

    # The admin owner holds delegable authority for both Template kinds, so the
    # full materialization lane emits #1/#2 scope caps plus #3/#4 preflight caps.
    # Count the four durable absorb artifacts themselves rather than assuming
    # exclusive ownership of any transport queue.
    assert eventually(fn -> length(pending_absorb_artifacts(orchestrator_uri)) == 4 end)

    refute Enum.any?(
             Ezagent.Identity.read_entity_caps(orchestrator_uri),
             &scoped_orchestrator_cap?/1
           )

    assert :ready =
             Ezagent.Kind.ReadyTransition.drain_pending_then_mark_ready(
               URI.to_string(orchestrator_uri),
               orchestrator_pid
             )

    assert eventually(fn ->
             orchestrator_uri
             |> Ezagent.Identity.read_entity_caps()
             |> Enum.filter(&scoped_orchestrator_cap?/1)
             |> scoped_orchestrator_cap_keys() ==
               MapSet.new([
                 {:session, :any, :any, {:within_session, session_uri}, @owner_uri},
                 {:agent, :any, :any, {:spawned_by, orchestrator_uri}, @owner_uri},
                 {:session_template, Ezagent.ActionSet.Template, :any,
                  {:within_workspace, @workspace_uri}, @owner_uri},
                 {:agent_template, Ezagent.ActionSet.Template, :any,
                  {:within_workspace, @workspace_uri}, @owner_uri}
               ])
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
             |> Enum.any?(&scoped_orchestrator_cap?/1)
             |> Kernel.not()
           end)
  end

  test "definitive fresh spawn failure tombstones its pre-spawn binding" do
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

    binding =
      RecipeCapBinding
      |> Repo.all()
      |> Enum.find(&(&1.recipe_name == recipe_name))

    assert %RecipeCapBinding{tombstoned_at: %DateTime{}} = binding
    assert RecipeCapBinding.fetch(Ezagent.URI.new!(binding.agent_uri)) == :not_found
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
    assert {:ok, %{pinged: false}} = Ezagent.Kind.get_slice(planned, :materialized_role_test)

    target = Ezagent.URI.with_action(planned, :materialized_role_test, :ping)

    assert {:ok, %{pong: true}} =
             Ezagent.Router.dispatch(
               Ezagent.Cmd.new(target, :ping, %{}, %{
                 mode: :call,
                 caller: @owner_uri,
                 caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()]),
                 reply: {:caller_inbox, self()}
               })
             )
  end

  test "orchestrator role materialization grants scoped delegation caps" do
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

    # Scoped-cap storage is now an intentional self-store cast. Materialization
    # returns once the hand-off is accepted, so observe eventual slice commit
    # instead of reintroducing a readiness/blocking barrier in the producer.
    assert eventually(fn ->
             caps = Ezagent.Identity.read_entity_caps(orchestrator_uri)

             Enum.any?(caps, fn cap ->
               cap.kind == :session and cap.instance == {:within_session, session_uri}
             end) and
               Enum.any?(caps, fn cap ->
                 cap.kind == :agent and cap.instance == {:spawned_by, orchestrator_uri}
               end)
           end)
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
  # condition for the cc-deepseek orchestrator) must be classified as a SKIP, not
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

  defp scoped_orchestrator_cap_keys(caps) do
    caps
    |> Enum.map(fn cap ->
      {
        cap.kind,
        cap.behavior,
        Ezagent.Capability.action_of(cap),
        cap.instance,
        cap.granted_by
      }
    end)
    |> MapSet.new()
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
      %{version: 1, op: :absorb_cap, cap: artifact} =
        :erlang.binary_to_term(payload, [:safe])

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
