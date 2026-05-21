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
        :ok = EzagentDomainChat.DefaultRules.bootstrap()

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

        # PR-M (Allen 2026-05-20) — idempotently spawn the default Echo
        # agent via SpawnRegistry. Previously the echo plugin used
        # `DynamicSupervisor.start_child` directly at its own boot,
        # bypassing `SpawnRegistry.spawn/1`. The echo plugin boots
        # before chat (no chat dep), so the `entity://` spawn fn isn't
        # registered yet at echo's boot time — chat (the last app)
        # invokes the standardized spawn here.
        :ok = ensure_echo_default()

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

  # PR-M (Allen 2026-05-20) — idempotently spawn the default Echo agent
  # via the standardized `Ezagent.SpawnRegistry.spawn/1` API. Previously
  # the echo plugin's own Application.start/2 called
  # `DynamicSupervisor.start_child/2` directly, bypassing the registry.
  # The echo plugin boots before chat (no chat dep), so the `entity://`
  # spawn fn isn't registered yet at echo's boot — this post-boot hook
  # in the last app to start (chat) does the spawn properly.
  #
  # `Code.ensure_loaded?` guards against test contexts where the echo
  # plugin isn't loaded. `{:already_started, _}` from SpawnRegistry is
  # treated as :ok (the echo plugin may have spawned via snapshot
  # rehydration before this hook runs).
  defp ensure_echo_default do
    if Code.ensure_loaded?(EzagentPluginEcho.Application) and
         function_exported?(EzagentPluginEcho.Application, :default_uri, 0) do
      do_ensure_echo_default(EzagentPluginEcho.Application.default_uri())
    else
      :ok
    end
  end

  defp do_ensure_echo_default(uri) do
    case Ezagent.SpawnRegistry.spawn(uri) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        require Logger

        Logger.warning(
          "ensure_echo_default: spawn failed (#{inspect(reason)}); " <>
            "F1 echo round-trip tests will fail until echo agent is available"
        )

        :ok
    end
  end

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
        Ezagent.Kind.spawn(Session, %{uri: uri})
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

  defp register_chat_behaviors do
    :ok = BehaviorRegistry.register(Session, :send, Chat)
    :ok = BehaviorRegistry.register(Session, :join, Chat)
    :ok = BehaviorRegistry.register(Session, :leave, Chat)
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
  #    The URI's name segment is `<flavor>_<name>`; the chat plugin
  #    knows the three built-in flavors (cc/curl/echo). Future agent
  #    flavors register their Template Class in step 2; the prefix
  #    fallback handles legacy / direct-spawn paths.
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
  # "curl.agent" registered by ezagent_plugin_curl_agent) map to Kind
  # modules. Echo has no Template Class — Echo agents live via boot-time
  # auto-spawn + snapshot.
  defp kind_module_from_class("cc.agent"), do: Ezagent.Entity.Agent
  defp kind_module_from_class("curl.agent"), do: Ezagent.Entity.CurlAgent
  defp kind_module_from_class("echo.agent"), do: Ezagent.Entity.Echo
  defp kind_module_from_class(_), do: nil

  # Flavor prefix (`cc_` / `curl_` / `echo_` / `test_`) → Kind module.
  # `test` agents (used as mention/routing fixtures) map to Entity.Agent
  # so the SpawnRegistry round-trip works in tests.
  defp kind_module_from_flavor("cc"), do: Ezagent.Entity.Agent
  defp kind_module_from_flavor("curl"), do: Ezagent.Entity.CurlAgent
  defp kind_module_from_flavor("echo"), do: Ezagent.Entity.Echo
  defp kind_module_from_flavor("test"), do: Ezagent.Entity.Agent
  defp kind_module_from_flavor(_), do: nil
end
