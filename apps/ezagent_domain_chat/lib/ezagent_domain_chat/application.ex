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
     reference, CLI spawn, or — for the default session — the
     first-login wizard at `/`).

  3. **No hardcoded default session** — PR-J removed the static
     `session://default/default/main` supervisor child. The wizard
     (`EzagentWeb.HomeLive`) creates the default session via
     `EzagentDomainChat.create_session/2` (which spawns + binds the
     default workspace + joins admin). In the `:test` environment,
     `maybe_seed_main_session_for_tests/0` calls the same facade at
     boot so the ~10 test suites asserting against boot-time
     `session://default/default/main` continue to pass without per-setup migration.

  ## Why use Ezagent.Entity.User from ezagent_core (not move it here)

  `admin_uri/0` + `admin_caps/0` are widely referenced (snapshot tests,
  invocation tests, LV admin page, plugin Echo integration tests).
  Keeping User in ezagent_core means readers don't depend on this plugin.

  Per the same reasoning, `Ezagent.Entity.User.behaviors/0` returns `[]`
  — Chat is wired in via per-Kind `BehaviorRegistry.register` rather
  than via `behaviors/0`, so ezagent_core stays free of any
  `Ezagent.Behavior.Chat` reference.
  """

  use Application

  alias Ezagent.{BehaviorRegistry, RoutingRegistry}
  alias Ezagent.Entity.{Agent, AgentTemplate, Session, SessionTemplate, User}
  alias Ezagent.Behavior.Chat
  alias EzagentDomainChat.Routing.{MentionRouting, SessionRouting}

  @impl true
  def start(_type, _args) do
    :ok = register_chat_behaviors()
    :ok = declare_routing_tables()

    # Phase 8c PR-J (Allen 2026-05-20) — `session://default/default/main` is no longer
    # a static supervisor child. The first-login wizard at `/` creates
    # the default session via the canonical `EzagentDomainChat.create_session/2`
    # facade (which binds workspace + joins admin). In `:test`
    # environment the previous boot behavior is preserved via
    # `seed_main_session_for_tests/0` below — too many tests (~10) hard-
    # coded `session://default/default/main` alive at boot to require setup migration in
    # a single PR. Dev / prod boot WITHOUT session://default/default/main; the wizard
    # populates it on first user visit.
    children = [
      {DynamicSupervisor, name: EzagentDomainChat.AgentSupervisor, strategy: :one_for_one},
      {DynamicSupervisor, name: EzagentDomainChat.SessionSupervisor, strategy: :one_for_one},
      # Phase 7 PR 37: supervisor for AgentTemplate Kinds. 0 children at
      # boot; templates materialize on admin create (LV or mix task) or
      # on snapshot restore at next reference.
      {DynamicSupervisor, name: EzagentDomainChat.AgentTemplateSupervisor, strategy: :one_for_one},
      # Phase 7 PR 38: supervisor for SessionTemplate Kinds. Same shape
      # as AgentTemplateSupervisor — 0 children at boot, lazy spawn.
      {DynamicSupervisor, name: EzagentDomainChat.SessionTemplateSupervisor, strategy: :one_for_one}
      # Phase 6 PR 2: admin User spawn moved to EzagentDomainIdentity.Application
      # (User Kind belongs to identity domain). Chat's start callback below
      # still dispatches admin → join default Session in test env only.
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

        # PR-M (Allen 2026-05-20) — idempotently persist
        # `workspace://default` so it shows up in `/workspaces` listing
        # and `/workspaces/default` detail loads. Previously the
        # default workspace existed only as a `WorkspaceRegistry.bind/2`
        # ETS entry (session→workspace), bypassing
        # `Ezagent.Workspace.create/2` (the canonical "persist + spawn"
        # API). Now goes through the same path every operator-created
        # workspace uses. Test-env skip — see helper docstring.
        :ok = ensure_default_workspace()

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
        # reference `template://agent/default/cc-orchestrator` without operator
        # setup. Idempotent: re-install on existing template is a no-op.
        :ok = seed_cc_orchestrator_template()

        # Phase 8c PR-J — test-only main session seed. See moduledoc.
        :ok = maybe_seed_main_session_for_tests()

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
  # apps/ezagent_*) assert against `session://default/default/main` alive at boot. Until
  # those setups are migrated to per-test seeding, the chat Application
  # creates the default session in `:test` env via the same canonical
  # `EzagentDomainChat.create_session/2` facade the wizard uses. In
  # `:dev` and `:prod` this is a no-op — the wizard at `/` creates main
  # on the operator's first login.
  defp maybe_seed_main_session_for_tests do
    if test_env?() do
      # PR-M (2026-05-20) — `create_session/2` now demand-spawns the
      # creator via SpawnRegistry before dispatching `chat.join` (see
      # `join_creator/2`). Admin User Kind is no longer a static child;
      # the demand-spawn covers the gap so admin appears in
      # session://default/default/main's members map post-seed.
      case EzagentDomainChat.create_session("main", User.admin_uri()) do
        {:ok, _uri} -> :ok
        # Identity domain may not have spawned admin User yet on first
        # boot — surface as a warning, not a crash. Tests that depend
        # on this seed will set their own setup-time seeding if needed.
        {:error, reason} ->
          require Logger

          Logger.warning(
            "test seed of session://default/default/main failed: #{inspect(reason)}; tests asserting on boot-time main may fail"
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

  # PR-M (Allen 2026-05-20) — idempotently persist the default workspace
  # via the standard `Ezagent.Workspace.create/2` API. Previously the
  # default existed only as a session→workspace ETS binding via
  # `Ezagent.WorkspaceRegistry.bind/2`; the Workspace row was never
  # created in SQLite, so `/workspaces` listed nothing and
  # `/workspaces/default` returned "not found".
  #
  # Idempotency: skip if the row exists. DB-unavailable at boot is
  # logged and tolerated — next boot retries (same pattern as workspace
  # loader).
  #
  # Test-env skip: boot-time DB writes interact poorly with Ecto SQL
  # Sandbox checkout in tests that don't use DataCase (the Audit.Writer
  # GenServer mid-flush blocks Sandbox.checkout). Tests that need the
  # row can call `Ezagent.Workspace.create("default", %{})` explicitly
  # in setup; the UI verification path is dev/prod-only.
  defp ensure_default_workspace do
    if test_env?() do
      :ok
    else
      # Phase 9 PR-8 (SPEC v3 §13.4) — order matters: system workspace
      # is created first so admin's URI (`entity://user/system/admin`)
      # resolves its workspace; then default for regular users.
      :ok = ensure_workspace("system", %{visible: false})
      :ok = ensure_workspace("default", %{})
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

  # Phase 7 PR 45 — seed cc-orchestrator AgentTemplate at boot.
  #
  # The cc-orchestrator is the LLM-driven session-internal manager
  # (Decision D7-1, #136). Every SessionTemplate's
  # `orchestrator_template_uri` field defaults to
  # `template://agent/default/cc-orchestrator` — so the template must exist
  # by the time the Generator (PR 41) tries to spawn an orchestrator
  # instance. This boot-time seed makes that resolution work
  # out-of-the-box in dev / single-host deployments.
  #
  # Slice values use placeholder defaults pointing at the operator's
  # current `~/.claude/` — production multi-tenant deployments will
  # configure per-template `claude_config_dir` to isolate sandboxes
  # (D7-2 AgentTemplate slice fields). macOS Keychain caveat applies
  # — multi-orchestrator on one mac shares Keychain credentials; use
  # `api_key_helper` or separate OS users (skill anti-pattern + runbook).
  #
  # Spawn semantics: SpawnRegistry returns `{:error, {:already_started, _}}`
  # if the Kind is already alive (snapshot restore on subsequent
  # boots); this fn treats that as success per the boot-seed
  # idempotency convention.
  defp seed_cc_orchestrator_template do
    uri = URI.parse("template://agent/default/cc-orchestrator")

    case Ezagent.SpawnRegistry.spawn(uri) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} ->
        require Logger
        Logger.warning(
          "Failed to seed cc-orchestrator template at boot: #{inspect(reason)}; " <>
            "orchestrator-style SessionTemplate instantiation will fail until manually created"
        )
        :ok
    end
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
            # PR-M (2026-05-20): special-case admin URI to seed
            # `initial_caps: User.admin_caps()`. Non-admin users have
            # caps_json hydrated via the login path's
            # `Ezagent.Entity.ensure_spawned/1` (see ezagent/entity.ex);
            # admin has no login path (password is nil until operator
            # sets it), so demand-spawn from a `chat.join` dispatch
            # (caller=admin) needs the bootstrap caps inline.
            initial_caps =
              if uri == User.admin_uri() do
                User.admin_caps()
              else
                MapSet.new()
              end

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
    :ok = BehaviorRegistry.register(Session, :send, Chat)
    :ok = BehaviorRegistry.register(Session, :join, Chat)
    :ok = BehaviorRegistry.register(Session, :leave, Chat)
    # Phase 7 completion PR-4 (SPEC §1.6) — the Generator + the
    # orchestrator slot tools write the durable `template_working_copy`
    # field via `?action=chat.set_working_copy` on the Session Kind.
    :ok = BehaviorRegistry.register(Session, :set_working_copy, Chat)
    :ok = BehaviorRegistry.register(User, :receive, Chat)
    :ok = BehaviorRegistry.register(Agent, :receive, Chat)
    # Phase 6 PR 2: Identity behavior registration (list_caps / has_cap?)
    # moved to ezagent_domain_identity.Application — Identity is the identity
    # domain's concern, not chat's.

    # PR #146 (SPEC v2 §5.7) — session-scoped routing rule mutations
    # dispatch to `session://<name>?action=routing.<action>` against
    # the Session Kind. The synthetic `routing-admin://default`
    # singleton is dissolved; rules naturally cap-scope to their session.
    alias Ezagent.Behavior.Routing, as: RB

    Enum.each(RB.actions(), fn action ->
      :ok = BehaviorRegistry.register(Session, action, RB)
    end)

    # Domain.Pty PR-B (2026-05-21 SPEC v1) — register the PTY Behavior
    # on the Agent Kind. Behavior module lives in ezagent_domain_pty;
    # the Kind ↔ Behavior binding happens here because this is where
    # `Ezagent.Entity.Agent` is defined. Previously registered from
    # `EzagentPluginCc.Application.start/2` (PR #146); moved here so
    # the PTY runtime is no longer plugin-cc-specific (any flavor whose
    # template `spawns_with: [Ezagent.Domain.Pty.Server]` reuses the
    # same dispatch path).
    alias Ezagent.Behavior.Pty, as: PtyB

    Enum.each(PtyB.actions(), fn action ->
      :ok = BehaviorRegistry.register(Agent, action, PtyB)
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
      :ok = BehaviorRegistry.register(AgentTemplate, action, TemplateB)
      :ok = BehaviorRegistry.register(SessionTemplate, action, TemplateB)
    end)

    :ok
  end

  # Phase 3a-step 4: declare 2 RoutingRegistry tables that this plugin
  # owns. MentionRouting is :duplicate (one matcher can fire on many
  # messages; one matcher → list of receivers; one rule per row).
  # SessionRouting is :unique (bridge_id → session_uri). Both declared
  # in this Application process — it owns writes.
  defp declare_routing_tables do
    :ok = RoutingRegistry.declare_table(MentionRouting, key_uniqueness: :duplicate)
    :ok = RoutingRegistry.declare_table(SessionRouting, key_uniqueness: :unique)
    :ok
  end

  # Phase 8c PR-J — `kind_server_spec/4`, `bind_default_session_to_default_workspace/0`,
  # and `admin_user_joins_default_session/0` removed. All three were
  # workarounds for the static-child `session://default/default/main` bypass. The
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

  # Template Class names (e.g. "cc.agent" registered by ezagent_plugin_cc;
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
