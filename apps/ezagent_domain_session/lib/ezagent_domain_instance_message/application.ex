defmodule EzagentDomainInstanceMessage.Application do
  @moduledoc """
  Chat plugin OTP application.

  ## Boot sequence (Phase 8c PR-J)

  1. **Register Chat Behaviors per-Kind subset** (BehaviorRegistry) —
     before spawning any Kind so dispatch routes correctly on first
     message:

         Ezagent.Entity.Session  → :send | :join | :leave  → Ezagent.ActionSet.Session
         Ezagent.Entity.User     → :receive               → Ezagent.ActionSet.User.Receive
         Ezagent.Entity.Agent    → :receive               → Ezagent.ActionSet.Agent.Receive

     PR #141 (SPEC v2): User+Agent merged into the `entity://` scheme;
     `Kind` modules are unchanged (`Ezagent.Entity.User` /
     `Ezagent.Entity.Agent` keep their existing names — the URI shape
     changed, not the OTP topology).

     Per Decision P2-D2 K-path: one Behavior module, multiple Kinds
     each picking the subset of actions it consumes.

  2. **Children supervisor** — DynamicSupervisors for Agent / Session /
     AgentTemplate / SessionTemplate Kinds. All start with zero
     children; Kinds materialize on demand (snapshot restore on
     reference, CLI spawn, or — for the operator's first session —
     the first-login wizard at `/`).

  3. **No hardcoded default session** — PR-J removed the static
     `session://default/system/main` supervisor child. The wizard
     (`EzagentWeb.HomeLive`) creates the operator's first session via
     `Ezagent.Workspace.create_session/3` (which spawns + binds the
     chosen workspace + joins admin). In the `:test` environment,
     `maybe_seed_main_session_for_tests/0` calls the same facade at
     boot so legacy test suites asserting against boot-time
     `session://default/system/main` continue to pass; SPEC v2 PR-F
     left those tests untouched (test-fixture URIs only — the
     `default` workspace itself is no longer boot-seeded; PR-C
     #295).

  ## Why use Ezagent.Entity.User from ezagent_core (not move it here)

  `admin_uri/0` is widely referenced (snapshot tests,
  invocation tests, LV admin page, plugin Echo integration tests).
  Keeping User in ezagent_core means readers don't depend on this plugin.

  Per the same reasoning, `Ezagent.Entity.User.behaviors/0` returns `[]`
  — Chat is wired in via per-Kind `BehaviorRegistry.register` rather
  than via `behaviors/0`, so ezagent_core stays free of any
  `Ezagent.ActionSet.Session` reference.
  """

  use Application

  alias Ezagent.RoutingRegistry
  alias Ezagent.Entity.{AgentTemplate, Session, SessionTemplate, User}
  alias Ezagent.Socialware.DefinitionRegistry
  alias EzagentDomainInstanceMessage.Routing.MentionRouting
  alias EzagentDomainInstanceMessage.AgentModuleResolver

  @impl true
  def start(_type, _args) do
    :ok = register_session_behaviors()
    :ok = declare_routing_tables()

    # PR-8 (transport #53) — the orchestrator-MCP transport subsystem
    # (`McpRegistry`/`LiveJoinRegistry`/`McpChannel`/`McpServer`/`Tools`/…) +
    # its `OrchestratorReadinessPort` impl registration RELOCATED into the cc
    # plugin (`EzagentPluginCc.Application.after_boot/0`). This app now only
    # owns the port + its neutral fallback (spec §3.6); the cc-resident
    # `ReadinessAdapter` is registered at cc boot. The session never names a
    # transport module, keeping `im → session → agent` acyclic.

    # Phase 8c PR-J (Allen 2026-05-20) — `session://default/system/main` is no longer
    # a static supervisor child. The first-login wizard at `/` creates
    # the default session via the canonical `Ezagent.Workspace.create_session/3`
    # facade (which binds workspace + joins admin). In `:test`
    # environment the previous boot behavior is preserved via
    # `seed_main_session_for_tests/0` below — too many tests (~10) hard-
    # coded `session://default/system/main` alive at boot to require setup migration in
    # a single PR. Dev / prod boot WITHOUT session://default/system/main; the wizard
    # populates it on first user visit.
    children = [
      # PR-9a (#53): the Agent + AgentTemplate DynamicSupervisors moved to
      # `EzagentDomainAgent.Application` (frozen names — D1a). Only the Session
      # supervisors remain in the session domain.
      {DynamicSupervisor,
       name: EzagentDomainInstanceMessage.SessionSupervisor, strategy: :one_for_one},
      # Phase 7 PR 38: supervisor for SessionTemplate Kinds. 0 children at
      # boot, lazy spawn.
      {DynamicSupervisor,
       name: EzagentDomainInstanceMessage.SessionTemplateSupervisor, strategy: :one_for_one},
      # Phase 6 PR 2: admin User spawn moved to EzagentDomainIdentity.Application
      # (User Kind belongs to identity domain). Chat's start callback below
      # still dispatches admin → join default Session in test env only.

      # Presence SPEC `docs/superpowers/specs/2026-05-23-presence.md` rev 3
      # §8 + Decision Log #93 — fan out `Ezagent.Presence` diffs into
      # per-session `:events` topics. Subscribes to
      # `esr:session_membership:changes` (broadcast by
      # `Ezagent.ActionSet.Session.broadcast_membership/2`) to maintain a
      # reverse `user_uri → MapSet(session_uri)` index.
      EzagentDomainInstanceMessage.PresenceFanout,
      # #17 PR-C2 — subscribes to the shared PTY auth-failure topic and notifies an
      # agent's owner (creator_uri) to re-`/login`, instead of the silent mute.
      Ezagent.Agent.CredentialNotifier,
      # Transport #53 Decision C — the per-orchestrator MCP executor
      # (`Ezagent.Session.SessionManager`, a GenServer NOT a Kind): Registry keys
      # it by orchestrator URI (cc reaches it by URI, no compile dep); the
      # DynamicSupervisor owns the per-session processes.
      {Registry, keys: :unique, name: Ezagent.Session.SessionManagerRegistry},
      {DynamicSupervisor, name: Ezagent.Session.SessionManagerSupervisor, strategy: :one_for_one},
      # send-echo-decouple (2026-07-08) — per-recipient message delivery runs
      # OFF the Session Kind's hot path in an UNLINKED supervised Task, so one
      # dead/slow member (e.g. a cold np-flavor agent whose `ensure_live` spawn
      # blocks ~5s) never delays the sender echo, the pipeline, or other members.
      # `Ezagent.ActionSet.Session.Delivery.deliver_async/5` starts children here.
      {Task.Supervisor, name: Ezagent.Session.DeliverySupervisor}
    ]

    case Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__) do
      {:ok, sup_pid} ->
        # Fail-closed (codex review — HIGH-2): bootstrap/0 returns
        # {:error, reason} when the system_default migration cannot
        # complete cleanly (transaction rolled back, registry NOT
        # reloaded). Crash the boot loudly rather than run on a
        # partially-migrated routing store.
        case EzagentDomainInstanceMessage.DefaultRules.bootstrap() do
          :ok ->
            :ok

          {:error, reason} ->
            raise "EzagentDomainInstanceMessage boot aborted — routing default-rule " <>
                    "migration failed (fail-closed): #{inspect(reason)}"
        end

        # PR #141 (SPEC v2): chat plugin now owns the unified `entity://`
        # scheme + `session://`. The identity domain's user:// spawn fn
        # is removed; identity's UserSupervisor is referenced by name
        # from inside the entity:// dispatch in `register_spawn_fns/0`.
        :ok = register_spawn_fns()

        # Phase 4-completion: register Template Classes this plugin provides.
        :ok = register_template_classes()

        # PR-A unify-uri-query — publish storage-backed attribute resolvers
        # as soon as the owning domain is booted. Callers distinguish this
        # readiness from "resolver ran and found no value" via
        # `{:error, {:no_resolver, attr}}` vs `:none`.
        :ok = EzagentDomainInstanceMessage.UriQueryResolvers.register()

        # Phase 4c: load persisted Workspaces — runs here because chat is
        # the last domain app to boot, so all spawn fns are registered.
        # PR 12 closeout: replace with an explicit registry-ready gate.
        :ok = EzagentDomainWorkspace.Application.boot_complete()

        # PR-M (Allen 2026-05-20) — idempotently persist the system
        # workspace via the canonical `Ezagent.Workspace.create/2` API.
        # SPEC v2 PR-C (#295) deleted the seeded `default` workspace —
        # only the hidden `system` workspace is boot-seeded now. PR-F
        # (this PR) renamed the helper from `ensure_default_workspace`
        # to match what it actually seeds. Test-env skip — see helper
        # docstring.
        :ok = ensure_system_workspace()

        :ok = seed_builtin_socialware_definitions()
        :ok = seed_manifest_boot_recipes()

        # sw-home lane (2026-07-07) — the early domain_session-priv-only
        # `ManifestSeed` scan was DELETED. All socialware manifests live in the
        # single deployment seed directory (`$EZAGENT_HOME/<profile>/socialware`,
        # seeded from `ezagent_web/priv/socialware_seed`) and are collected by
        # ONE late scan, `Ezagent.Socialware.ManifestSeed.scan_all!/1`, triggered
        # from `EzagentWeb.Application` after every plugin has booted — manifests
        # may reference plugin-registered views/recipes, which do not exist
        # yet at this point of the boot sequence.

        # Plugin authoring contract PR-5 codex HIGH-2 — the default
        # agent is NO LONGER seeded here. Seeding it from chat's
        # `start/2` was a boot-order race: the resolver needs the flavor
        # registered via `Ezagent.AgentFlavorRegistry`, published by the
        # flavor plugin's `boot/1`, but `ezagent_domain_session` does not
        # depend on the flavor plugin — so the seed could fire before
        # `agent_flavors/0` was registered, fail with
        # `{:no_kind_module_for_agent, ...}`, log, and never retry → the
        # default agent absent. The seed now lives in the flavor plugin's
        # `after_boot/0` (P2: the py plugin seeds `py_default`), which by
        # construction runs after `agent_flavors/0` is published; the
        # plugin declares a dep on `ezagent_domain_session` so the
        # `entity://` spawn dispatcher is registered first.

        # PR-8 (transport #53) — the cc-orchestrator AgentTemplate seed
        # (`Ezagent.Orchestrator.CcOrchestratorSeed.seed/0`) RELOCATED to
        # `EzagentPluginCc.Application.after_boot/0` (approved seed relocation)
        # together with the `CcOrchestratorSeed` module. This app no longer
        # names that module. The `default` SessionTemplate seed below stays
        # here and only stores the orchestrator AgentTemplate *URI* by value
        # (`template://agent/system/cc-orchestrator`) in the template content —
        # it never requires the AgentTemplate Kind to be alive at this point,
        # so the relocation is behavior-identical (same URI, seeded by cc later).

        # Task #50 (Allen 2026-05-27) — seed a `default` SessionTemplate
        # under `workspace://system` so `/admin/templates` is non-empty
        # on a fresh install AND so `mix ezagent workspace create_session
        # --template-name default` resolves to a known team config
        # without operator setup. Idempotent (content-addressable: same
        # config → same hash URI → already-alive). The default template's
        # `orchestrator_template_uri` points at the cc-orchestrator
        # AgentTemplate URI (seeded by the cc plugin's after_boot).
        :ok = seed_default_session_template()

        # Phase 8c PR-J — test-only main session seed.
        #
        # 2026-05-31 orchestrator-startup-atomicity §4 — MOVED to
        # `EzagentPluginCc.Application.after_boot/0`. The atomic
        # `create_session/3` rolls back when the orchestrator can't be
        # ensured, and the orchestrator's `"cc"` flavor is registered by
        # the cc plugin AFTER this app boots — so seeding here always
        # tore `main` back down. Same boot-order fix as the echo seed.

        # PR-M (Allen 2026-05-20) — admin User Kind is NOT auto-spawned
        # at boot. The static `kind_server_spec(:user_admin, ...)` child
        # in `EzagentDomainIdentity.Application` was removed; admin now
        # spawns lazily via SpawnRegistry on first dispatch reference
        # (login, session join, cap lookup). Tests that need the admin
        # Kind alive at boot must call
        # `Ezagent.SpawnRegistry.spawn(Ezagent.Entity.User.admin_uri())`
        # in setup — `EzagentDomainInstanceMessage.ApplicationTest` is the
        # canonical example.

        {:ok, sup_pid}

      other ->
        other
    end
  end

  # Test-environment seed: many existing test suites (~10 across
  # apps/ezagent_*) assert against `session://default/system/main` alive at boot. Until
  # those setups are migrated to per-test seeding, the chat Application
  # creates the default session in `:test` env via the same canonical
  # Workspace create-session path the wizard uses. In
  # `:dev` and `:prod` this is a no-op — the wizard at `/` creates main
  # on the operator's first login.
  @doc """
  Test-only seed of `session://default/system/main`.

  2026-05-31 orchestrator-startup-atomicity §4 — this seed is now
  invoked from `EzagentPluginCc.Application.after_boot/0` (NOT from this
  app's `start/2`), because the atomic `create_session/3` rolls the
  session back when the orchestrator can't be ensured. The orchestrator
  needs the `"cc"` agent flavor, which the cc plugin registers AFTER
  `ezagent_domain_session` boots — so seeding here at chat-boot time always
  failed with `{:orchestrator_ensure_failed, {:unknown_flavor, "cc"}}`
  and tore `main` down (the same boot-order race the echo seed hit, now
  fixed the same way — defer to the plugin's `after_boot`). Idempotent.
  """
  @spec maybe_seed_main_session_for_tests() :: :ok
  def maybe_seed_main_session_for_tests do
    if test_env?() do
      # PR-M (2026-05-20) — create-session now demand-spawns the
      # creator via SpawnRegistry before dispatching `chat.join`. Admin
      # User Kind is no longer a static child; the demand-spawn covers
      # the gap so admin appears in main's members map post-seed.
      # SPEC #366 (Allen 2026-05-26): `:template_name` is required. Pass
      # `"default"` explicitly to preserve the existing
      # `session://default/system/main` URI shape that ~10 test suites
      # assert against.
      result =
        with :ok <- ensure_system_workspace_seeded_for_tests(),
             :ok <- maybe_seed_stock_orchestrator_recipe_for_tests() do
          Ezagent.Workspace.create_session(
            Ezagent.URI.workspace(:system),
            %{short_name: "main", template_name: "default"},
            %{
              caller: User.admin_uri(),
              caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()])
            }
          )
        end

      case result do
        # SPEC `2026-05-26-session-create-orchestrator-unified` Gap A —
        # `create_session/3` now returns a result map including
        # orchestrator status. Bootstrap seed only needs the session
        # itself; orchestrator failure here is non-fatal (test env
        # rarely exercises the orchestrator anyway — its e2e tests
        # spawn explicitly).
        {:ok, _result} ->
          :ok

        # Identity domain may not have spawned admin User yet on first
        # boot — surface as a warning, not a crash. Tests that depend
        # on this seed will set their own setup-time seeding if needed.
        {:error, reason} ->
          require Logger

          Logger.warning(
            "test seed of #{URI.to_string(Ezagent.Entity.Session.default_uri())} failed: #{inspect(reason)}; tests asserting on boot-time main may fail"
          )

          :ok
      end
    else
      :ok
    end
  end

  defp test_env? do
    Code.ensure_loaded?(Mix) and Mix.env() == :test
  rescue
    _ -> false
  end

  defp maybe_seed_stock_orchestrator_recipe_for_tests do
    module = Module.concat([Ezagent, Orchestrator, OrchestratorRecipe])

    if Code.ensure_loaded?(module) and function_exported?(module, :recipe, 0) do
      module
      |> apply(:recipe, [])
      |> Ezagent.Agent.RecipeRegistry.seed_role_if_absent()
      |> case do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp ensure_system_workspace_seeded_for_tests do
    case Ezagent.Workspace.Store.get_by_name("system") do
      nil ->
        case Ezagent.Workspace.create("system", %{created_by: User.admin_uri()}) do
          {:ok, _pid} -> :ok
          {:error, :workspace_exists} -> :ok
          {:error, {:already_started, _pid}} -> :ok
          {:error, reason} -> {:error, {:system_workspace_seed_failed, reason}}
        end

      _ ->
        :ok
    end
  end

  defp register_template_classes do
    :ok = Ezagent.TemplateRegistry.register(Ezagent.Template.GenericSession)
    :ok
  end

  # SPEC v2 PR-C (#295) + PR-F (this PR) — only `workspace://system`
  # is boot-seeded. `admin`'s URI is `entity://user/system/admin`
  # (Allen: 这个 user 唯一); membership in `system` confers cross-
  # workspace authority via `Ezagent.Capability.cross_workspace?/2`.
  # Regular users land in their email-domain workspace via the
  # onboarding flow (PR-B #294); tests that need a workspace create
  # one explicitly per setup.
  #
  # Idempotency: skip if the row exists. DB-unavailable at boot is
  # logged and tolerated — next boot retries (same pattern as workspace
  # loader).
  #
  # Test-env skip: boot-time DB writes interact poorly with Ecto SQL
  # Sandbox checkout in tests that don't use DataCase (the Audit.Writer
  # GenServer mid-flush blocks Sandbox.checkout).
  defp ensure_system_workspace do
    if test_env?() do
      :ok
    else
      # SPEC 2026-05-27-workspace-cap-based-visibility §4.2 — the
      # `:visible` field is gone. Visibility is cap-derived via
      # `Ezagent.Workspace.list_workspaces_for/2`; the system workspace
      # is hidden from non-members structurally, no per-row flag.
      :ok = ensure_workspace("system", %{})
    end
  end

  defp ensure_workspace(name, attrs) do
    try do
      case Ezagent.Workspace.Store.get_by_name(name) do
        nil ->
          case Ezagent.Workspace.create(name, attrs) do
            {:ok, _pid} ->
              :ok

            {:error, {:already_started, _pid}} ->
              # Kind already alive but no Store row — happens if a
              # prior boot bound via WorkspaceRegistry without
              # persisting. Re-attempt just the Store row.
              case Ezagent.Workspace.Store.create(name, attrs) do
                {:ok, _} -> :ok
                # #533 5a — Store.create signals an already-present row as
                # {:exists, _}; here that's the goal (row exists), so :ok.
                {:exists, _} -> :ok
                {:error, _} -> :ok
              end

            {:error, reason} ->
              require Logger

              Logger.warning(
                "ensure_workspace(#{inspect(name)}): create failed (#{inspect(reason)}); " <>
                  "/workspaces listing will be incomplete until next boot"
              )

              :ok
          end

        _existing ->
          :ok
      end
    rescue
      e in [DBConnection.ConnectionError, DBConnection.OwnershipError] ->
        require Logger

        Logger.warning(
          "ensure_workspace(#{inspect(name)}): DB unavailable at boot (#{inspect(e.__struct__)}); " <>
            "Workspace provisioning deferred to next boot"
        )

        :ok
    end
  end

  # Plugin authoring contract PR-5 codex HIGH-2 — the default-agent seed
  # was removed from here. Seeding a default agent from chat's boot raced
  # the flavor plugin's `agent_flavors/0` registration (chat does not
  # depend on the flavor plugin). The seed lives in the flavor plugin's
  # `after_boot/0` — P2: `EzagentPluginPy.Application.after_boot/0` seeds
  # the default py-agent (`py_default`), which replaced the old
  # default agent.

  # Task #50 (Allen 2026-05-27) seeded a `default` SessionTemplate Kind
  # under `workspace://system`. Task #27 extends the invariant: every
  # workspace that creates a `"default"` session must resolve a
  # workspace-local `template://session/<workspace>/default@<hash>`.
  # This keeps `session://default/team-alpha/main` from looking for a
  # system-owned template or failing with
  # `{:session_template_not_found, "default", "team-alpha"}`.
  #
  # Minimal-viable config: no legacy `members`, empty `routing_rules` (no
  # auto-routing), and installs `chat` + `orchestrator`. The orchestrator is a
  # stock socialware Definition materialized through the same install path as
  # every other default contribution.
  #
  # ## Idempotency (content-addressable)
  #
  # `SessionTemplate.persist_version_as_system/2` hashes the content,
  # builds `template://session/<workspace>/default@<hash>`, and spawns
  # the Kind. Re-running this seed with identical content resolves to the
  # SAME URI and `SpawnRegistry.spawn/1` returns `{:ok, _existing_pid}`
  # — no duplicate row in `kind_snapshots`. Hash inputs include
  # `members`, `routing_rules`, `prompt_templates`, `legends`,
  # `orchestrator_template_uri`, and
  # `default_workspace_uri`; `created_at`/`created_by` are explicitly
  # excluded (see `SessionTemplate.compute_version_hash/1`) so wall-
  # clock skew across reboots doesn't churn the hash.
  #
  # ## Best-effort (won't abort boot)
  #
  # A persist failure (DB unavailable, AgentTemplate seed errored)
  # logs a warning and returns `:ok`. The next boot retries — same
  # pattern as `ensure_system_workspace/0` and the cc-orchestrator
  # seed.
  # 2026-05-31 orchestrator-startup-atomicity §3 — the `"default"`
  # SessionTemplate is a HARD boot invariant in prod/dev: the
  # orchestrator-bearing default template MUST exist so `create_session`
  # can resolve `"default"` (the wizard + Feishu + `mix create_session`
  # all default to it). If it can't persist, crash the boot LOUDLY rather
  # than run a system where every default create fails with
  # `{:session_template_not_found, "default", _}` (fail-loud, no degrade —
  # `feedback_let_it_crash_no_workarounds`).
  #
  # `:test` is CARVED OUT: test already skips `ensure_system_workspace`
  # (boot-time DB writes interact poorly with Ecto SQL Sandbox checkout)
  # and uses its own sandbox seed — DataCase tests that need the default
  # template drive `seed_default_session_template_now/0` inside an active
  # checkout. A hard crash here would break the whole suite's boot.
  defp seed_default_session_template do
    if test_env?() do
      _ = do_seed_default_session_template(Ezagent.URI.workspace(:system))
      :ok
    else
      case seed_default_session_templates_for_existing_workspaces() do
        :ok ->
          :ok

        {:error, reason} ->
          raise "EzagentDomainInstanceMessage boot aborted — the `default` SessionTemplate " <>
                  "(orchestrator-bearing) could not be persisted (fail-closed, §3): " <>
                  "#{inspect(reason)}. Every `create_session(... template_name: \"default\")` " <>
                  "would fail to resolve the template; refusing to boot."
      end
    end
  end

  defp seed_builtin_socialware_definitions do
    case DefinitionRegistry.seed_builtin_definitions() do
      :ok ->
        :ok

      {:error, reason} ->
        if test_env?() do
          :ok
        else
          raise "EzagentDomainInstanceMessage boot aborted — built-in socialware " <>
                  "definitions could not be persisted: #{inspect(reason)}"
        end
    end
  end

  defp seed_manifest_boot_recipes do
    if Ezagent.Socialware.ManifestSeed.enabled?() do
      case Ezagent.Agent.RecipeRegistry.seed_role_if_absent(%{name: "autoservice-agent"}) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          raise "EzagentDomainInstanceMessage boot aborted — local socialware manifest " <>
                  "recipe seeds could not be persisted: #{inspect(reason)}"
      end
    else
      :ok
    end
  end

  @doc """
  Public test-only entry point — invoke the default SessionTemplate
  seed deterministically (e.g. from inside an active Ecto Sandbox
  checkout). Production code should NEVER call this directly; the
  boot path already runs the seed via `seed_default_session_template/0`
  above. Exposed for invariant tests that want to drive the seed
  without depending on boot-order side effects.

  Codex review #419 round-1 HIGH-1 — test-side escape hatch (the
  boot-time path was kept because the cc-orchestrator seed at the
  preceding line does boot-time Repo writes too, and that precedent
  has been stable across the suite).
  """
  @spec seed_default_session_template_now() :: :ok | {:error, :test_only}
  def seed_default_session_template_now do
    seed_default_session_template_now(Ezagent.URI.workspace(:system))
  end

  @doc """
  Test-only variant of `seed_default_session_template_now/0` for a
  specific workspace.

  Used by tests that create tenant workspaces inside an Ecto Sandbox
  checkout. Production callers should use
  `ensure_default_session_template/1`, which is the non-test, normal
  runtime API used by `EzagentDomainInstanceMessage.SessionCreator.create_session/3`.
  """
  @spec seed_default_session_template_now(URI.t() | String.t()) :: :ok | {:error, :test_only}
  def seed_default_session_template_now(workspace) do
    # codex review #419 r2 HIGH-1: this entry is test-only. Prod callers
    # must use the boot path (Application.start/2 invokes
    # do_seed_default_session_template/1 once at startup). Reject calls
    # outside test env so a stale operator script can't accidentally
    # double-seed prod.
    if test_env?() do
      ensure_default_session_template(workspace)
    else
      {:error, :test_only}
    end
  end

  @doc """
  Ensure a workspace-local `default` SessionTemplate exists.

  This is a normal runtime API, not a test escape hatch. It creates the
  content-addressed `template://session/<workspace>/default@<hash>` for
  the exact workspace passed in. It does not fall back to
  `workspace://system`; if persistence fails, the caller receives the
  concrete error and should fail loudly.
  """
  @spec ensure_default_session_template(URI.t() | String.t()) :: :ok | {:error, term()}
  def ensure_default_session_template(workspace) do
    workspace
    |> workspace_uri!()
    |> do_seed_default_session_template()
  end

  defp seed_default_session_templates_for_existing_workspaces do
    existing_workspace_uris()
    |> Enum.reduce_while(:ok, fn workspace_uri, :ok ->
      case do_seed_default_session_template(workspace_uri) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {workspace_uri, reason}}}
      end
    end)
  end

  defp existing_workspace_uris do
    system = Ezagent.URI.workspace(:system)

    workspaces =
      try do
        Ezagent.Workspace.Store.list_all()
        |> Enum.map(fn ws -> Ezagent.URI.workspace(ws.name) end)
      rescue
        _ -> []
      end

    [system | workspaces]
    |> Enum.uniq_by(&URI.to_string/1)
  end

  defp do_seed_default_session_template(%URI{scheme: "workspace"} = workspace_uri) do
    workspace_name = Ezagent.URI.workspace_name!(workspace_uri)

    content = %{
      name: "default",
      description:
        "Default session template — orchestrator-only team. Compose " <>
          "the team via the orchestrator's member + rule-set tools. " <>
          "Seeded under `#{URI.to_string(Ezagent.URI.workspace(workspace_name))}` so " <>
          "`mix ezagent workspace create_session --template-name default` " <>
          "and the LV New-session form resolve without operator setup.",
      # team-routing-unification §3.7 (PR-7) — SessionTemplate content carries
      # `members` (in_session_template members) / `prompt_templates` / `legends`;
      # `agent_slots` is NO LONGER a content field (PR-8 removes the slot tools).
      # The default template delegates stock front-desk provisioning to the
      # orchestrator socialware Definition; legacy `members` stays empty.
      members: [],
      prompt_templates: %{},
      installs: ["chat", "orchestrator"],
      legends: %{},
      routing_rules: [],
      default_workspace_uri: workspace_uri,
      parent_template_uri: nil,
      version_tag: nil,
      created_by: nil,
      # `nil` instead of `DateTime.utc_now()` so a re-run of the seed
      # writes the SAME content (no per-boot snapshot churn). The
      # version hash already excludes `created_at` but the snapshot
      # row stores the full content; using `nil` keeps that row stable.
      created_at: nil
    }

    # 2026-05-31 orchestrator-startup-atomicity §3 — PROPAGATE the failure
    # (no longer swallow to `:ok`). The prod/dev caller
    # (`seed_default_session_template/0`) turns a `{:error, _}` into a hard
    # boot crash; the test caller tolerates it (Sandbox). Logging stays so
    # the failure is visible regardless of which caller handles it.
    hash = Ezagent.Entity.SessionTemplate.compute_version_hash(content)
    uri = Ezagent.Entity.SessionTemplate.build_uri("default", hash, workspace: workspace_name)
    :ok = clear_live_template_without_snapshot(uri)

    case Ezagent.Entity.SessionTemplate.persist_version_as_system(content, workspace_uri) do
      {:ok, _uri} ->
        # fix/template-name-resolution — repoint the `default`→`current`
        # TemplateTag at the version just persisted, so name resolution
        # takes the deterministic tag path (`TemplateResolver.find_session_
        # template_uri` tries `TemplateTags.resolve(ws, "default", "current")`
        # first) and the by-scan fallback is only ever a true fallback. When
        # new code ships a new `default` version, THIS is the exact moment a
        # new version is persisted, so it is the exact moment the tag must
        # repoint. `put/5` is an unconditional upsert: idempotent when the
        # hash is unchanged, upgrade-aware (repoint) when it changed.
        #
        # Log-and-continue on a tag-write failure: the scan fallback is now
        # deterministic-newest, so a missing/stale tag degrades to correct
        # (just slower) resolution rather than a boot crash.
        case Ezagent.TemplateTags.put(workspace_uri, "default", "current", hash, nil) do
          :ok ->
            :ok

          {:error, tag_reason} ->
            require Logger

            Logger.warning(
              "seed_default_session_template: tag `default`→`current` write failed: " <>
                "#{inspect(tag_reason)} (uri=#{URI.to_string(uri)}). Name resolution " <>
                "falls back to the deterministic-newest scan; not fatal."
            )

            :ok
        end

      {:error, reason} ->
        require Logger

        Logger.error(
          "seed_default_session_template: persist failed: #{inspect(reason)} — " <>
            "the orchestrator-bearing `default` SessionTemplate is the boot " <>
            "invariant create_session resolves `template_name: \"default\"` against. " <>
            "§3 hard-fails boot in prod/dev on this error."
        )

        {:error, reason}
    end
  rescue
    e ->
      require Logger

      Logger.error("seed_default_session_template raised #{inspect(e)} — §3 boot invariant.")

      {:error, {:seed_default_session_template_raised, e}}
  end

  defp clear_live_template_without_snapshot(uri) do
    if Ezagent.Ecto.KindSnapshot.get(URI.to_string(uri)) == nil do
      Ezagent.Kind.terminate(uri)
    else
      :ok
    end
  end

  defp workspace_uri!(%URI{scheme: "workspace"} = workspace_uri), do: workspace_uri

  defp workspace_uri!(workspace) when is_binary(workspace) do
    case Ezagent.URI.parse(workspace) do
      {:ok, %URI{} = uri} ->
        if Ezagent.URI.scheme?(uri, :workspace), do: uri, else: Ezagent.URI.workspace(workspace)

      {:error, _reason} ->
        Ezagent.URI.workspace(workspace)
    end
  end

  defp register_spawn_fns do
    # PR #141 (SPEC v2): `user://` + `agent://` schemes are deleted;
    # both merge into `entity://`. The chat plugin owns the unified
    # `entity://` spawn fn — dispatch by `Ezagent.URI.type/1`:
    #
    # - `entity://user/<name>` → spawn `Ezagent.Entity.User` under
    #   `EzagentDomainIdentity.Application.UserSupervisor` (identity
    #   domain owns User Kind; chat references its supervisor by
    #   module name per task spec).
    # - `entity://agent/<workspace>/<name>` → resolve the backing
    #   `kind_module` via `lookup_kind_module_for_agent/1` (snapshot →
    #   workspace-template → stored flavor) and spawn under
    #   `EzagentDomainInstanceMessage.AgentSupervisor`.
    #
    # PR #149 (SPEC v2 §5.14): `Ezagent.AgentTypeRegistry` deleted.
    # Per-flavor lookup table replaced by snapshot-first /
    # template-second / stored-flavor resolution. Plugins no longer
    # register flavor → spawn fn pairs; Template Class registration
    # and stored agent flavor are the declarative channel for new
    # agent flavors.
    :ok =
      Ezagent.SpawnRegistry.register("entity", fn uri ->
        case Ezagent.URI.type(uri) do
          {:ok, "user"} ->
            # PR-M (2026-05-20): special-case admin URI to seed the
            # bootstrap caps. SPEC caps-cleanup-v1 §4.4 (PR-CC-1):
            # admin's caps are conceptually granted by
            # `system://bootstrap` — `SystemPrincipal.caps/1` mints the
            # equivalent MapSet from the closed Catalog.
            #
            # Non-admin users: hydrate from `users.caps_json` so the
            # initial slice carries the same cap set the bootstrap row
            # was created with (wildcard-cap-fix 2026-05-26). The
            # earlier `MapSet.new()` default produced a slice without
            # `mix ezagent.user.create --caps '*'`'s wildcard cap; the
            # snapshot then froze that empty state forever (see
            # `Ezagent.Entity.User.initial_caps_for_spawn/1`).
            #
            # Login-mediated demand-spawn via
            # `Ezagent.Entity.ensure_spawned/1` still uses its own
            # `spawn_with_hydrated_caps/1` path; this fix closes the
            # OTHER entry points (mix tasks, LV WorkspaceUserAdmin)
            # that pre-fix routed through the empty default.
            initial_caps = User.initial_caps_for_spawn(uri)

            # V1 prevention (Allen 2026-05-21): route via Ezagent.Kind.spawn/2.
            # User Kind's supervisor/0 callback resolves the destination
            # (EzagentDomainIdentity.Application.UserSupervisor) — chat
            # plugin no longer needs to name a sibling domain's supervisor.
            Ezagent.Kind.spawn(User, %{uri: uri, initial_caps: initial_caps})

          {:ok, "agent"} ->
            spawn_agent(uri)

          other ->
            {:error, {:unknown_entity_host, other}}
        end
      end)

    :ok =
      Ezagent.SpawnRegistry.register("session", fn uri ->
        # V1 prevention (Allen 2026-05-21): route via Ezagent.Kind.spawn/2.
        # P5-0b: thread the explicit chat behavior set so `init_set/2` stores a
        # non-nil `:kind_base` (the scoped guard requires it for sessions).
        # P5-1b: `Session.behaviors/0` is now the UNION, so this DEMAND-SPAWN /
        # rehydrate route passes the chat SUBSET (`chat_behaviors/0`). NB this is
        # the `:not_found` first-spawn path's set; for an EXISTING snapshot the
        # reload branch derives the effective set from the PERSISTED `:kind_base`
        # (a socialware row keeps its socialware set), so a cold-rehydrated
        # socialware session is NOT downgraded to chat by this default (P5-2 /
        # the rehydration test). This covers the SpawnRegistry "session" route,
        # which `GenericSession.instantiate/3` also funnels through.
        result = Ezagent.Kind.spawn(Session, %{uri: uri, behaviors: Session.chat_behaviors()})

        # Allen V1 acceptance 2026-05-22 (invariant 4): rebind the
        # session → workspace consistency cache on EVERY spawn,
        # including the lazy demand-spawn rehydrate path after a phx
        # restart. Session Kind is now {:snapshot, :on_change} —
        # membership rehydrates from `kind_snapshots`, but the
        # WorkspaceRegistry ETS binding does NOT survive a restart
        # (ETS is in-memory). Without rebinding here, a rehydrated
        # session that's referenced via a bare `SpawnRegistry.spawn`
        # (not `create_session/2`) would have no workspace binding →
        # `Ezagent.ActionSet.Session.invoke(:send)` resolves
        # `workspace_uri: nil` and workspace-scoped routing rules
        # silently never fire. Per Phase 9 PR-7 the workspace is in
        # the 3-segment session URI, so the binding is derived
        # structurally — no DB lookup needed.
        case result do
          {:ok, _pid} -> bind_session_workspace(uri)
          {:error, {:already_started, _pid}} -> bind_session_workspace(uri)
          _ -> :ok
        end

        # Decision C cold-restart self-heal — restart the per-orchestrator
        # `SessionManager` from the rehydrated session's durable working copy.
        case result do
          {:ok, _} -> _ = Ezagent.Session.SessionManager.ensure_for_session(uri)
          _ -> :ok
        end

        result
      end)

    # Phase 7 PR 37: template:// scheme dispatches on type segment.
    # `template://<workspace>/agent/<name>` → AgentTemplate Kind.
    # `template://<workspace>/session/<name>@<hash>` → SessionTemplate Kind (PR 38).
    # The single spawn fn for the scheme switches on Ezagent.URI.type/1 so
    # both Template Kinds share the same scheme namespace without
    # colliding on the registry.
    :ok =
      Ezagent.SpawnRegistry.register("template", fn uri ->
        case Ezagent.URI.type(uri) do
          {:ok, "agent"} ->
            # V1 prevention (Allen 2026-05-21): route via Ezagent.Kind.spawn/2.
            Ezagent.Kind.spawn(AgentTemplate, %{uri: uri})

          {:ok, "session"} ->
            # V1 prevention (Allen 2026-05-21): route via Ezagent.Kind.spawn/2.
            Ezagent.Kind.spawn(SessionTemplate, %{uri: uri})

          other ->
            {:error, {:unknown_template_host, other}}
        end
      end)

    :ok
  end

  # Allen V1 acceptance 2026-05-22 (invariant 4) — derive the workspace
  # URI structurally from the 3-segment session URI
  # (`session://<template>/<workspace>/<name>`, Phase 9 PR-7) and bind
  # it in `Ezagent.WorkspaceRegistry`. Called from the `session` spawn
  # fn so the binding is (re)established on every spawn — crucially the
  # lazy demand-spawn path that rehydrates a snapshotted Session after
  # a phx restart, where ETS bindings were lost. `Capability.workspace_of/1`
  # returns `:any` only for cross-cutting schemes; a `session://` URI
  # always yields a concrete `workspace://` URI, so the bind always runs.
  defp bind_session_workspace(%URI{scheme: "session"} = session_uri) do
    case Ezagent.Capability.workspace_of(session_uri) do
      %URI{} = workspace_uri ->
        :ok = Ezagent.WorkspaceRegistry.bind(session_uri, workspace_uri)

      :any ->
        :ok
    end
  end

  defp bind_session_workspace(_other), do: :ok

  defp register_session_behaviors,
    do: EzagentDomainInstanceMessage.SessionBehaviorRegistration.register()

  # Declare the chat plugin's RoutingRegistry table.
  #
  # MentionRouting is :duplicate (one matcher can fire on many
  # messages; one matcher → list of receivers; one rule per row).
  # Declared in this Application process — it owns writes.
  #
  # NOTE (2026-05-25): the sibling SessionRouting table was deleted
  # in this PR — its Feishu chat ↔ session bridge responsibility now
  # lives in the ExternalMirror domain's `external_mirror_bindings`
  # table (PR-EM-3 #317). See `Ezagent.ExternalMirror` facade.
  defp declare_routing_tables do
    :ok = RoutingRegistry.declare_table(MentionRouting, key_uniqueness: :duplicate)
    :ok
  end

  # Phase 8c PR-J — `kind_server_spec/4`, `bind_default_session_to_default_workspace/0`,
  # and `admin_user_joins_default_session/0` removed. All three were
  # workarounds for the static-child `session://default/system/main` bypass. The
  # wizard's call to `Ezagent.Workspace.create_session/3` does the
  # bind + admin join in one place — same code path for every session,
  # including the default.

  # PR #149 (SPEC v2 §5.14) + unify-uri-query PR-B — agent flavor
  # resolution without `Ezagent.AgentTypeRegistry` or URI-name parsing.
  # Three-step lookup:
  #
  # 1. Snapshot — restart case. KindSnapshot stores `kind_type` for
  #    every persisted Kind; the chat plugin maps it back to the Kind
  #    module. Fast, single DB row by URI.
  # 2. Workspace template — first-spawn-after-template-creation case.
  #    Walks `Ezagent.Workspace.Store.list_all/0` looking for a
  #    session_template whose `agent_uri` matches; the template's
  #    `class` string ("cc.agent" / "curl.agent" / ...) maps to a Kind
  #    module.
  # 3. Stored flavor — boot-time auto-spawn / CLI-driven spawn case.
  #    The owning domain resolves `:flavor` through `Ezagent.UriQuery`,
  #    then maps the stored flavor through `Ezagent.AgentFlavorRegistry`
  #    (plugin authoring contract SPEC §6.3 / codex MEDIUM-5 — each
  #    agent-flavor plugin declares `agent_flavors/0`,
  #    `Ezagent.Plugin.boot/1` registers it).
  defp spawn_agent(%URI{} = uri) do
    case AgentModuleResolver.lookup_kind_module_for_agent(uri) do
      {:ok, kind_module} ->
        # V1 prevention (Allen 2026-05-21): route via Ezagent.Kind.spawn/2.
        # Each agent Kind (Agent / CurlAgent / PyAgent) declares its own
        # supervisor/0 callback; chat plugin no longer hardcodes
        # `EzagentDomainInstanceMessage.AgentSupervisor` (CurlAgent in particular
        # has its own InstanceSupervisor under the curl_agent plugin).
        Ezagent.Kind.spawn(kind_module, %{uri: uri})

      {:error, reason} ->
        {:error, reason}

      :error ->
        {:error, {:no_kind_module_for_agent, URI.to_string(uri)}}
    end
  end

  # Agent-URI → Kind-module resolution lives in
  # `EzagentDomainInstanceMessage.AgentModuleResolver` (#25 Phase-3
  # PR-3P); `spawn_agent/1` above delegates to it then spawns.
end
