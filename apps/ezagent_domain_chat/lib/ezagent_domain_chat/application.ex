defmodule EzagentDomainChat.Application do
  @moduledoc """
  Chat plugin OTP application.

  ## Boot sequence (Phase 8c PR-J)

  1. **Register Chat Behaviors per-Kind subset** (BehaviorRegistry) —
     before spawning any Kind so dispatch routes correctly on first
     message:

         Ezagent.Entity.Session  → :send | :join | :leave  → Ezagent.Behavior.Chat
         Ezagent.Entity.User     → :receive               → Ezagent.Behavior.Chat
         Ezagent.Entity.Agent    → :receive               → Ezagent.Behavior.Chat

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
     `EzagentDomainChat.create_session/2` (which spawns + binds the
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
  `Ezagent.Behavior.Chat` reference.
  """

  use Application

  alias Ezagent.{CapabilityRegistry, RoutingRegistry}
  alias Ezagent.Entity.{Agent, AgentTemplate, Session, SessionTemplate, User}
  alias Ezagent.Behavior.Chat
  alias EzagentDomainChat.Routing.MentionRouting

  @impl true
  def start(_type, _args) do
    :ok = register_chat_behaviors()
    :ok = declare_routing_tables()

    # Phase 7 completion PR-5 — the `orchestrator_uri → bound
    # McpServer context` ETS table. The Generator registers a row when
    # it spawns an orchestrator; `Ezagent.Orchestrator.McpChannel`
    # (the MCP transport bridge's BEAM endpoint) looks it up. Same
    # lazy-`init/0` pattern as the AgentBridge registry.
    :ok = Ezagent.Orchestrator.McpRegistry.init()

    # Phase 8c PR-J (Allen 2026-05-20) — `session://default/system/main` is no longer
    # a static supervisor child. The first-login wizard at `/` creates
    # the default session via the canonical `EzagentDomainChat.create_session/2`
    # facade (which binds workspace + joins admin). In `:test`
    # environment the previous boot behavior is preserved via
    # `seed_main_session_for_tests/0` below — too many tests (~10) hard-
    # coded `session://default/system/main` alive at boot to require setup migration in
    # a single PR. Dev / prod boot WITHOUT session://default/system/main; the wizard
    # populates it on first user visit.
    children = [
      {DynamicSupervisor, name: EzagentDomainChat.AgentSupervisor, strategy: :one_for_one},
      {DynamicSupervisor, name: EzagentDomainChat.SessionSupervisor, strategy: :one_for_one},
      # Phase 7 PR 37: supervisor for AgentTemplate Kinds. 0 children at
      # boot; templates materialize on admin create (LV or mix task) or
      # on snapshot restore at next reference.
      {DynamicSupervisor,
       name: EzagentDomainChat.AgentTemplateSupervisor, strategy: :one_for_one},
      # Phase 7 PR 38: supervisor for SessionTemplate Kinds. Same shape
      # as AgentTemplateSupervisor — 0 children at boot, lazy spawn.
      {DynamicSupervisor,
       name: EzagentDomainChat.SessionTemplateSupervisor, strategy: :one_for_one},
      # Phase 6 PR 2: admin User spawn moved to EzagentDomainIdentity.Application
      # (User Kind belongs to identity domain). Chat's start callback below
      # still dispatches admin → join default Session in test env only.

      # Presence SPEC `docs/superpowers/specs/2026-05-23-presence.md` rev 3
      # §8 + Decision Log #93 — fan out `Ezagent.Presence` diffs into
      # per-session `:events` topics. Subscribes to
      # `esr:session_membership:changes` (broadcast by
      # `Ezagent.Behavior.Chat.broadcast_membership/2`) to maintain a
      # reverse `user_uri → MapSet(session_uri)` index.
      EzagentDomainChat.PresenceFanout
    ]

    case Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__) do
      {:ok, sup_pid} ->
        # Fail-closed (codex review — HIGH-2): bootstrap/0 returns
        # {:error, reason} when the system_default migration cannot
        # complete cleanly (transaction rolled back, registry NOT
        # reloaded). Crash the boot loudly rather than run on a
        # partially-migrated routing store.
        case EzagentDomainChat.DefaultRules.bootstrap() do
          :ok ->
            :ok

          {:error, reason} ->
            raise "EzagentDomainChat boot aborted — routing default-rule " <>
                    "migration failed (fail-closed): #{inspect(reason)}"
        end

        # PR #141 (SPEC v2): chat plugin now owns the unified `entity://`
        # scheme + `session://`. The identity domain's user:// spawn fn
        # is removed; identity's UserSupervisor is referenced by name
        # from inside the entity:// dispatch in `register_spawn_fns/0`.
        :ok = register_spawn_fns()

        # Phase 4-completion: register Template Classes this plugin provides.
        :ok = register_template_classes()

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

        # Plugin authoring contract PR-5 codex HIGH-2 — the default
        # Echo agent is NO LONGER seeded here. Seeding the echo agent
        # from chat's `start/2` was a boot-order race: the resolver
        # needs `Ezagent.AgentFlavorRegistry.lookup("echo")` to have
        # been published by the echo plugin's `boot/1`, but
        # `ezagent_domain_chat` does not depend on `ezagent_plugin_echo`
        # — so the seed could fire before echo's `agent_flavors/0` was
        # registered, fail with `{:no_kind_module_for_agent, ...}`, log,
        # and never retry → the default echo agent absent. The seed now
        # lives in `EzagentPluginEcho.Application.after_boot/0`, which
        # by construction runs after echo's `agent_flavors/0` is
        # published; echo declares a dep on `ezagent_domain_chat` so the
        # `entity://` spawn dispatcher is registered first.

        # Phase 7 PR 45: install the cc-orchestrator AgentTemplate seed
        # so SessionTemplate-instantiation paths (PR 41 Generator) can
        # reference `template://agent/system/cc-orchestrator` without operator
        # setup. Idempotent: re-install on existing template is a no-op.
        :ok = seed_cc_orchestrator_template()

        # Task #50 (Allen 2026-05-27) — seed a `default` SessionTemplate
        # under `workspace://system` so `/admin/templates` is non-empty
        # on a fresh install AND so `mix ezagent workspace create_session
        # --template-name default` resolves to a known team config
        # without operator setup. Idempotent (content-addressable: same
        # config → same hash URI → already-alive). Depends on
        # `seed_cc_orchestrator_template/0` because the default template's
        # `orchestrator_template_uri` points at the cc-orchestrator
        # AgentTemplate URI.
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
        # in setup — `EzagentDomainChat.ApplicationTest` is the
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
  # `EzagentDomainChat.create_session/2` facade the wizard uses. In
  # `:dev` and `:prod` this is a no-op — the wizard at `/` creates main
  # on the operator's first login.
  @doc """
  Test-only seed of `session://default/system/main`.

  2026-05-31 orchestrator-startup-atomicity §4 — this seed is now
  invoked from `EzagentPluginCc.Application.after_boot/0` (NOT from this
  app's `start/2`), because the atomic `create_session/3` rolls the
  session back when the orchestrator can't be ensured. The orchestrator
  needs the `"cc"` agent flavor, which the cc plugin registers AFTER
  `ezagent_domain_chat` boots — so seeding here at chat-boot time always
  failed with `{:orchestrator_ensure_failed, {:unknown_flavor, "cc"}}`
  and tore `main` down (the same boot-order race the echo seed hit, now
  fixed the same way — defer to the plugin's `after_boot`). Idempotent.
  """
  @spec maybe_seed_main_session_for_tests() :: :ok
  def maybe_seed_main_session_for_tests do
    if test_env?() do
      # PR-M (2026-05-20) — `create_session/2` now demand-spawns the
      # creator via SpawnRegistry before dispatching `chat.join`. Admin
      # User Kind is no longer a static child; the demand-spawn covers
      # the gap so admin appears in main's members map post-seed.
      # SPEC #366 (Allen 2026-05-26): `:template_name` is required. Pass
      # `"default"` explicitly to preserve the existing
      # `session://default/system/main` URI shape that ~10 test suites
      # assert against.
      case EzagentDomainChat.create_session("main", User.admin_uri(), template_name: "default") do
        # SPEC `2026-05-26-session-create-orchestrator-unified` Gap A —
        # `create_session/3` now returns a 3-tuple including
        # orchestrator status. Bootstrap seed only needs the session
        # itself; orchestrator failure here is non-fatal (test env
        # rarely exercises the orchestrator anyway — its e2e tests
        # spawn explicitly).
        {:ok, _uri, _meta} ->
          :ok

        # Identity domain may not have spawned admin User yet on first
        # boot — surface as a warning, not a crash. Tests that depend
        # on this seed will set their own setup-time seeding if needed.
        {:error, reason} ->
          require Logger

          Logger.warning(
            "test seed of session://default/system/main failed: #{inspect(reason)}; tests asserting on boot-time main may fail"
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

  # Plugin authoring contract PR-5 codex HIGH-2 — `ensure_echo_default/0`
  # + `do_ensure_echo_default/1` were removed from here. Seeding the
  # default echo agent from chat's boot raced the echo plugin's
  # `agent_flavors/0` registration (chat does not depend on
  # ezagent_plugin_echo). The seed moved to
  # `EzagentPluginEcho.Application.after_boot/0`.

  # Phase 7 PR 45 + completion PR-5 — seed the cc-orchestrator
  # AgentTemplate at boot with a REAL `:template` slice.
  #
  # The cc-orchestrator is the LLM-driven session-internal manager
  # (Decision D7-1, #136). Every SessionTemplate's
  # `orchestrator_template_uri` field defaults to
  # `template://agent/system/cc-orchestrator` — so the template must
  # exist by the time the Generator tries to spawn an orchestrator
  # instance.
  #
  # Pre-PR-5 this seed only spawned an EMPTY AgentTemplate Kind. PR-5
  # delegates to `Ezagent.Orchestrator.CcOrchestratorSeed.seed/0`, which
  # populates a real slice (`flavor: "cc"`, an isolated
  # `claude_config_dir`, a `settings.json`, an `mcp_config_path` pointing
  # at the orchestrator MCP server, a system prompt) so a Generator-
  # spawned orchestrator comes up fully configured. The seed is
  # idempotent (AgentTemplate `:write` is a mutable replace) and
  # best-effort (logs + `:ok` on failure so boot never aborts).
  defp seed_cc_orchestrator_template do
    Ezagent.Orchestrator.CcOrchestratorSeed.seed()
  end

  # Task #50 (Allen 2026-05-27) — seed a `default` SessionTemplate Kind
  # under `workspace://system` so admin can immediately use
  # `mix ezagent workspace create_session --template-name default`
  # without operator setup, and `/admin/templates` is non-empty on a
  # fresh install.
  #
  # Minimal-viable config (per task spec): empty `agent_slots` (no
  # worker agents — just the orchestrator), empty `routing_rules`
  # (no auto-routing), `orchestrator_template_uri` pointing at the
  # cc-orchestrator AgentTemplate seeded in
  # `seed_cc_orchestrator_template/0` above. A session instantiated
  # from this template spawns only the orchestrator — the orchestrator
  # then composes its team via `add_agent_slot` / `write_matcher`
  # tools.
  #
  # ## Idempotency (content-addressable)
  #
  # `SessionTemplate.persist_version_as_system/2` hashes the content,
  # builds `template://session/system/default@<hash>`, and spawns the
  # Kind. Re-running this seed with identical content resolves to the
  # SAME URI and `SpawnRegistry.spawn/1` returns `{:ok, _existing_pid}`
  # — no duplicate row in `kind_snapshots`. Hash inputs include
  # `agent_slots`, `routing_rules`, `orchestrator_template_uri`, and
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
      _ = do_seed_default_session_template()
      :ok
    else
      case do_seed_default_session_template() do
        :ok ->
          :ok

        {:error, reason} ->
          raise "EzagentDomainChat boot aborted — the `default` SessionTemplate " <>
                  "(orchestrator-bearing) could not be persisted (fail-closed, §3): " <>
                  "#{inspect(reason)}. Every `create_session(... template_name: \"default\")` " <>
                  "would fail to resolve the template; refusing to boot."
      end
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
    # codex review #419 r2 HIGH-1: this entry is test-only. Prod callers
    # must use the boot path (Application.start/2 invokes
    # do_seed_default_session_template/0 once at startup). Reject calls
    # outside test env so a stale operator script can't accidentally
    # double-seed prod.
    if test_env?() do
      do_seed_default_session_template()
    else
      {:error, :test_only}
    end
  end

  defp do_seed_default_session_template do
    workspace_uri = Ezagent.URI.new!("workspace://system")
    orchestrator_uri = Ezagent.URI.new!(Ezagent.Orchestrator.CcOrchestratorSeed.template_uri())

    content = %{
      name: "default",
      description:
        "Default session template — orchestrator-only team. Compose " <>
          "workers via the orchestrator's `add_agent_slot` tool. " <>
          "Seeded at boot under `workspace://system` so " <>
          "`mix ezagent workspace create_session --template-name default` " <>
          "and the LV New-session form resolve without operator setup.",
      agent_slots: [],
      orchestrator_template_uri: orchestrator_uri,
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
    case Ezagent.Entity.SessionTemplate.persist_version_as_system(content, workspace_uri) do
      {:ok, _uri} ->
        :ok

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

      Logger.error(
        "seed_default_session_template raised #{inspect(e)} — §3 boot invariant."
      )

      {:error, {:seed_default_session_template_raised, e}}
  end

  defp register_spawn_fns do
    # PR #141 (SPEC v2): `user://` + `agent://` schemes are deleted;
    # both merge into `entity://`. The chat plugin owns the unified
    # `entity://` spawn fn — dispatch by `uri.host`:
    #
    # - `entity://user/<name>` → spawn `Ezagent.Entity.User` under
    #   `EzagentDomainIdentity.Application.UserSupervisor` (identity
    #   domain owns User Kind; chat references its supervisor by
    #   module name per task spec).
    # - `entity://agent/<flavor>_<name>` → resolve the backing
    #   `kind_module` via `lookup_kind_module_for_agent/1` (snapshot →
    #   workspace-template → flavor-prefix fallback) and spawn under
    #   `EzagentDomainChat.AgentSupervisor`.
    #
    # PR #149 (SPEC v2 §5.14): `Ezagent.AgentTypeRegistry` deleted.
    # Per-flavor lookup table replaced by snapshot-first /
    # template-second / prefix-fallback resolution. Plugins no longer
    # register flavor → spawn fn pairs; Template Class registration is
    # the declarative channel for new agent flavors.
    :ok =
      Ezagent.SpawnRegistry.register("entity", fn uri ->
        case uri.host do
          "user" ->
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

          "agent" ->
            spawn_agent(uri)

          other ->
            {:error, {:unknown_entity_host, other}}
        end
      end)

    :ok =
      Ezagent.SpawnRegistry.register("session", fn uri ->
        # V1 prevention (Allen 2026-05-21): route via Ezagent.Kind.spawn/2.
        result = Ezagent.Kind.spawn(Session, %{uri: uri})

        # Allen V1 acceptance 2026-05-22 (invariant 4): rebind the
        # session → workspace consistency cache on EVERY spawn,
        # including the lazy demand-spawn rehydrate path after a phx
        # restart. Session Kind is now {:snapshot, :on_change} —
        # membership rehydrates from `kind_snapshots`, but the
        # WorkspaceRegistry ETS binding does NOT survive a restart
        # (ETS is in-memory). Without rebinding here, a rehydrated
        # session that's referenced via a bare `SpawnRegistry.spawn`
        # (not `create_session/2`) would have no workspace binding →
        # `Ezagent.Behavior.Chat.invoke(:send)` resolves
        # `workspace_uri: nil` and workspace-scoped routing rules
        # silently never fire. Per Phase 9 PR-7 the workspace is in
        # the 3-segment session URI, so the binding is derived
        # structurally — no DB lookup needed.
        case result do
          {:ok, _pid} -> bind_session_workspace(uri)
          {:error, {:already_started, _pid}} -> bind_session_workspace(uri)
          _ -> :ok
        end

        result
      end)

    # Phase 7 PR 37: template:// scheme dispatches on host segment.
    # `template://agent/<name>` → AgentTemplate Kind.
    # `template://session/<name>@<hash>` → SessionTemplate Kind (PR 38).
    # The single spawn fn for the scheme switches on URI.host so
    # both Template Kinds share the same scheme namespace without
    # colliding on the registry.
    :ok =
      Ezagent.SpawnRegistry.register("template", fn uri ->
        case uri.host do
          "agent" ->
            # V1 prevention (Allen 2026-05-21): route via Ezagent.Kind.spawn/2.
            Ezagent.Kind.spawn(AgentTemplate, %{uri: uri})

          "session" ->
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

  defp register_chat_behaviors do
    :ok = CapabilityRegistry.register(Session, :send, Chat)
    :ok = CapabilityRegistry.register(Session, :join, Chat)
    :ok = CapabilityRegistry.register(Session, :leave, Chat)
    # Phase 7 completion PR-4 (SPEC §1.6) — the Generator + the
    # orchestrator slot tools write the durable `template_working_copy`
    # field via `?action=chat.set_working_copy` on the Session Kind.
    :ok = CapabilityRegistry.register(Session, :set_working_copy, Chat)
    :ok = CapabilityRegistry.register(User, :receive, Chat)
    :ok = CapabilityRegistry.register(Agent, :receive, Chat)
    # Phase 6 PR 2: Identity behavior registration (list_caps / has_cap?)
    # moved to ezagent_domain_identity.Application — Identity is the identity
    # domain's concern, not chat's.

    # PR #146 (SPEC v2 §5.7) — session-scoped routing rule mutations
    # dispatch to `session://<name>?action=routing.<action>` against
    # the Session Kind. The synthetic `routing-admin://default`
    # singleton is dissolved; rules naturally cap-scope to their session.
    alias Ezagent.Behavior.Routing, as: RB

    Enum.each(RB.actions(), fn action ->
      :ok = CapabilityRegistry.register(Session, action, RB)
    end)

    # Domain.Pty PR-B (2026-05-21 SPEC v1) — register the PTY Behavior
    # on the Agent Kind. Behavior module lives in ezagent_domain_pty;
    # the Kind ↔ Behavior binding happens here because this is where
    # `Ezagent.Entity.Agent` is defined. Previously registered from
    # the cc plugin application (PR #146); moved here so
    # the PTY runtime is no longer plugin-cc-specific (any flavor whose
    # template `spawns_with: [Ezagent.Domain.Pty.Server]` reuses the
    # same dispatch path).
    alias Ezagent.Behavior.Pty, as: PtyB

    Enum.each(PtyB.actions(), fn action ->
      :ok = CapabilityRegistry.register(Agent, action, PtyB)
    end)

    # Phase 7 completion PR-1 (SPEC §1.0) — register the new
    # `Ezagent.Behavior.Template` Behavior's three actions
    # (`:read` / `:write` / `:instantiate`) on BOTH Template Kinds.
    # After this, `?action=template.read` / `template.write` /
    # `template.instantiate` resolve through `BehaviorRegistry` on
    # either Template Kind and are dispatch-invocable; CapBAC step
    # 5.5 derives `behavior == Ezagent.Behavior.Template`.
    alias Ezagent.Behavior.Template, as: TemplateB

    Enum.each(TemplateB.actions(), fn action ->
      :ok = CapabilityRegistry.register(AgentTemplate, action, TemplateB)
      :ok = CapabilityRegistry.register(SessionTemplate, action, TemplateB)
    end)

    # ExternalMirror PR-EM-0 (SPEC `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`
    # §8.1, Allen 2026-05-25) — register the `Ezagent.Behavior.Publisher.SessionImpl`
    # Kind-Behavior on `Ezagent.Entity.Session`. The three publisher
    # actions (`:publisher_subscribe_from`, `:publisher_snapshot`,
    # `:publisher_history`) gate via standard step 5.5 CapBAC; the
    # session-side implementation owns the `:publisher` slice +
    # subscribes to its own SliceChange topic via `post_init/2`'s
    # continuation. SessionImpl is registered ONLY against Session
    # because Session is the V1 publisher (option (a) — implementer
    # lives in the publishing domain). Future publisher Kinds will
    # add their own per-Kind registration alongside this one.
    alias Ezagent.Behavior.Publisher.SessionImpl, as: PublisherSI

    Enum.each(PublisherSI.actions(), fn action ->
      :ok = CapabilityRegistry.register(Session, action, PublisherSI)
    end)

    # ExternalMirror PR-EM-3 (SPEC §4.1 / §9 PR-EM-3) — register
    # the `Ezagent.Behavior.ExternalMirror` (bind / unbind /
    # list_bindings) Behavior on `Ezagent.Entity.Session`. Per the
    # convention (`feedback_register_lookup_key_parity` / SPEC §5.1
    # step 7): Kind ↔ Behavior wiring lives in the app that DEFINES
    # the Kind — Session is here in `:ezagent_domain_chat`, so the
    # registration lives here even though the Behavior module ships
    # from `:ezagent_domain_external_mirror`.
    alias Ezagent.Behavior.ExternalMirror, as: ExternalMirrorBehavior

    Enum.each(ExternalMirrorBehavior.actions(), fn action ->
      :ok = CapabilityRegistry.register(Session, action, ExternalMirrorBehavior)
    end)

    # Phase 7 completion PR-5 (SPEC §1.6b) — register the core
    # `Ezagent.Behavior.Terminable` Behavior's `:terminate` action on the
    # Agent Kind. After this, `entity://agent/...?action=lifecycle.terminate`
    # resolves through `BehaviorRegistry` and is dispatch-invocable +
    # CapBAC-gated — so the orchestrator's `remove_agent_slot` /
    # `update_agent_template` tools terminate workers through dispatch,
    # NOT a bare `DynamicSupervisor.terminate_child` (which would bypass
    # CapBAC and let an orchestrator kill any agent). The orchestrator's
    # cap #2 (`{:spawned_by, orchestrator}`) is what permits it to
    # terminate only ITS OWN workers. (The dispatch action string stays
    # `lifecycle.terminate` — a cosmetic label; resolution is by the
    # `:terminate` action atom, not the prefix.)
    alias Ezagent.Behavior.Terminable, as: TerminableB

    Enum.each(TerminableB.actions(), fn action ->
      :ok = CapabilityRegistry.register(Agent, action, TerminableB)
    end)

    # PR2 2026-05-24 (Allen) — Sandbox Behavior registers the per-agent
    # config_dir + extension-management actions. Listed in
    # `Agent.behaviors/0` so init_slice fires; ALSO registered with
    # CapabilityRegistry so dispatch (read / write_path / destroy) goes
    # through CapBAC. Same pattern as Terminable above.
    alias Ezagent.Behavior.Sandbox, as: SandboxB

    Enum.each(SandboxB.actions(), fn action ->
      :ok = CapabilityRegistry.register(Agent, action, SandboxB)
    end)

    # RFC #402 (Allen 2026-05-26) — `OrchestratorAdmin` is a cap-only
    # Behavior anchoring the session-owner authority over this
    # session's orchestrator agent. `:restart` is the single cap
    # subject; held by the session owner (`slice.chat.owner_uri`) +
    # the bootstrap admin via `:any`. `OrchestratorHealthCard` in
    # `ezagent_plugin_liveview` consults this cap to gate the Restart
    # button. `dispatchable?: false` means the registration writes
    # ONLY the subject row; no dispatch path can accidentally invoke
    # `:restart` (same pattern as `Behavior.Presence`).
    alias Ezagent.Behavior.OrchestratorAdmin, as: OrchAdminB

    Enum.each(OrchAdminB.actions(), fn action ->
      :ok = CapabilityRegistry.register(Session, action, OrchAdminB)
    end)

    :ok
  end

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
  # wizard's call to `EzagentDomainChat.create_session/2` does the
  # bind + admin join in one place — same code path for every session,
  # including the default.

  # PR #149 (SPEC v2 §5.14) — agent flavor resolution without
  # `Ezagent.AgentTypeRegistry`. Three-step lookup:
  #
  # 1. Snapshot — restart case. KindSnapshot stores `kind_type` for
  #    every persisted Kind; the chat plugin maps it back to the Kind
  #    module. Fast, single DB row by URI.
  # 2. Workspace template — first-spawn-after-template-creation case.
  #    Walks `Ezagent.Workspace.Store.list_all/0` looking for a
  #    session_template whose `agent_uri` matches; the template's
  #    `class` string ("cc.agent" / "curl.agent" / ...) maps to a Kind
  #    module.
  # 3. Flavor prefix — boot-time auto-spawn / CLI-driven spawn case.
  #    The URI's name segment is `<flavor>_<name>`; the flavor is
  #    resolved via `Ezagent.AgentFlavorRegistry` (plugin authoring
  #    contract SPEC §6.3 / codex MEDIUM-5 — each agent-flavor plugin
  #    declares `agent_flavors/0`, `Ezagent.Plugin.boot/1` registers
  #    it). The `test` fixture flavor is the one non-plugin exception.
  defp spawn_agent(%URI{} = uri) do
    case lookup_kind_module_for_agent(uri) do
      {:ok, kind_module} ->
        # V1 prevention (Allen 2026-05-21): route via Ezagent.Kind.spawn/2.
        # Each agent Kind (Agent / CurlAgent / Echo) declares its own
        # supervisor/0 callback; chat plugin no longer hardcodes
        # `EzagentDomainChat.AgentSupervisor` (CurlAgent in particular
        # has its own InstanceSupervisor under the curl_agent plugin).
        Ezagent.Kind.spawn(kind_module, %{uri: uri})

      :error ->
        {:error, {:no_kind_module_for_agent, URI.to_string(uri)}}
    end
  end

  defp lookup_kind_module_for_agent(%URI{} = uri) do
    uri_str = URI.to_string(uri)

    with :error <- lookup_via_snapshot(uri_str),
         :error <- lookup_via_workspace_template(uri_str),
         :error <- lookup_via_flavor_prefix(uri) do
      :error
    else
      {:ok, _mod} = ok -> ok
    end
  end

  defp lookup_via_snapshot(uri_str) do
    case Ezagent.Ecto.KindSnapshot.get(uri_str) do
      %Ezagent.Ecto.KindSnapshot{kind_type: kt} when is_binary(kt) and kt != "" ->
        case kind_module_from_kind_type(kt) do
          nil -> :error
          mod -> {:ok, mod}
        end

      _ ->
        :error
    end
  rescue
    # DB unavailable at boot — fall through to next resolver step. The
    # snapshot is an optimization; missing it just means we hit step 2/3.
    _ -> :error
  end

  defp lookup_via_workspace_template(uri_str) do
    if Code.ensure_loaded?(Ezagent.Workspace.Store) do
      Ezagent.Workspace.Store.list_all()
      |> Enum.find_value(fn ws ->
        ws.session_templates
        |> Map.values()
        |> Enum.find_value(fn tmpl ->
          case tmpl do
            %{"agent_uri" => ^uri_str, "class" => class} when is_binary(class) ->
              kind_module_from_class(class)

            %{"agent_uri" => ^uri_str, class: class} when is_binary(class) ->
              kind_module_from_class(class)

            _ ->
              nil
          end
        end)
      end)
      |> case do
        nil -> :error
        mod -> {:ok, mod}
      end
    else
      :error
    end
  rescue
    # Same boot-time DB unavailability tolerance as step 1.
    _ -> :error
  end

  defp lookup_via_flavor_prefix(%URI{host: "agent", path: "/" <> rest}) when rest != "" do
    # Phase 9 PR-2 (SPEC v3 §3): entity URI is 3-segment
    # `/<workspace>/<entity_name>`; flavor lives in entity_name prefix.
    with [_workspace, entity_name] when entity_name != "" <-
           String.split(rest, "/", parts: 2),
         [flavor, suffix] when flavor != "" and suffix != "" <-
           String.split(entity_name, "_", parts: 2) do
      case kind_module_from_flavor(flavor) do
        nil -> :error
        mod -> {:ok, mod}
      end
    else
      _ -> :error
    end
  end

  defp lookup_via_flavor_prefix(_), do: :error

  # KindSnapshot.kind_type is `to_string(kind_module.type_name())` per
  # the Snapshot writer (kind/snapshot.ex). Map back to the Kind module.
  defp kind_module_from_kind_type("agent"), do: Ezagent.Entity.Agent
  defp kind_module_from_kind_type("curl_agent"), do: Ezagent.Entity.CurlAgent
  defp kind_module_from_kind_type("echo"), do: Ezagent.Entity.Echo
  defp kind_module_from_kind_type(_), do: nil

  # Template Class names (e.g. "cc.agent" registered by the cc plugin;
  # "curl.agent" by ezagent_plugin_curl_agent; "echo.agent" by
  # ezagent_plugin_echo) map to Kind modules.
  #
  # Plugin authoring contract SPEC §6.3 + codex MEDIUM-5: the
  # flavor→{kind, template_class} mapping is no longer hardcoded here —
  # each agent-flavor plugin declares `agent_flavors/0` and
  # `Ezagent.Plugin.boot/1` registers it in
  # `Ezagent.AgentFlavorRegistry`. This resolver consults that registry
  # instead. Adding a 6th agent-flavor plugin now touches only that
  # plugin's own dir. The decl carries the `template_class` module, so
  # a Template Class NAME (e.g. "cc.agent") is matched against
  # `template_class.template_name/0`.
  defp kind_module_from_class(class) when is_binary(class) do
    Enum.find_value(Ezagent.AgentFlavorRegistry.list_all(), fn
      {_flavor, %{kind: kind, template_class: tc}} ->
        if class_name(tc) == class, do: kind, else: nil
    end)
  end

  defp kind_module_from_class(_), do: nil

  defp class_name(template_class) do
    template_class.template_name()
  rescue
    # A declared template_class module that does not (yet) export
    # `template_name/0` — tolerate it (the snapshot / flavor-prefix
    # resolver steps still cover the spawn).
    _ -> nil
  end

  # Flavor prefix (`cc_` / `curl_` / `echo_` / `test_`) → Kind module.
  #
  # Plugin authoring contract SPEC §6.3 + codex MEDIUM-5: real agent
  # flavors (cc / curl / echo) resolve via `Ezagent.AgentFlavorRegistry`
  # — populated by each plugin's `agent_flavors/0` declaration through
  # `Ezagent.Plugin.boot/1`. The registry is published before this
  # resolver runs at dispatch time (the plugin apps boot, and
  # `boot/1`'s Phase 2 registers the flavor, well before any
  # `entity://agent/...` dispatch); a not-yet-registered flavor returns
  # `:error` from `lookup/1` and this fn returns `nil` — the caller
  # then yields `{:error, {:no_kind_module_for_agent, _}}` rather than
  # crashing (graceful boot-ordering tolerance).
  #
  # `test` is NOT a plugin flavor — `test_*` agents are mention/routing
  # test fixtures with no owning plugin; they map to the shared
  # `Ezagent.Entity.Agent` Kind so the SpawnRegistry round-trip works
  # in tests. It is kept as an explicit non-registry fallback.
  defp kind_module_from_flavor("test"), do: Ezagent.Entity.Agent

  defp kind_module_from_flavor(flavor) when is_binary(flavor) do
    case Ezagent.AgentFlavorRegistry.lookup(flavor) do
      {:ok, %{kind: kind}} -> kind
      :error -> nil
    end
  end

  defp kind_module_from_flavor(_), do: nil
end
