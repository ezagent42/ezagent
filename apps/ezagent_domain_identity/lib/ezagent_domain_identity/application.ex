defmodule EzagentDomainIdentity.Application do
  @moduledoc """
  Identity domain OTP application — Phase 6 PR 2.

  Owns:
  - `Ezagent.Entity.User` Kind (per-user spawn fn registered here, full
    `entity://` fn registered by chat plugin which boots later)
  - `Ezagent.Behavior.Identity` registration on User + Agent
  - `Ezagent.Users` SQLite provisioning (Phase 4-completion Spec 05)

  Does NOT own (Chat plugin owns those):
  - `Ezagent.Behavior.Chat` :receive registration on User/Agent
  - Session boot or admin-join-default-session

  ## Boot order

  Must start BEFORE any plugin that depends on User (chat, ezagent, ...).
  Umbrella resolves this via the `{:ezagent_domain_identity, in_umbrella: true}`
  dep in those apps' mix.exs.

  ## Phase 8c PR-M — admin user creation goes through standard API

  Allen 2026-05-20: previously, `entity://user/system/admin` was eagerly spawned
  as a static supervisor child via `kind_server_spec/4`, bypassing the
  same `Ezagent.Users.create/3` API every other user uses (and the
  `mix ezagent.user.create` task uses). The admin had no row in the
  `users` table, breaking `mix ezagent.user.set_password entity://user/system/admin`
  on fresh DBs.

  PR-M removes the static child; the admin User Kind now spawns lazily
  via the `entity://` SpawnRegistry fn on first dispatch reference
  (e.g. `Ezagent.Workspace.create_session/3` joins admin while creating the session).
  The DB row is provisioned at boot via `ensure_admin_user/0` — idempotent
  `Ezagent.Users.create/3` with `password: nil` (matches the
  `mix ezagent.user.create` flow when `--password` is omitted; first login
  requires `mix ezagent.user.set_password` first, same as any other user).
  """

  use Application

  alias Ezagent.{CapabilityRegistry, SpawnRegistry}
  alias Ezagent.Entity.User
  alias Ezagent.Behavior.{Identity, ApiKeys, UserCredentials, UserTokens, WorkspaceUserAdmin}

  @impl true
  def start(_type, _args) do
    :ok = register_identity_behaviors()

    children = [
      {DynamicSupervisor, name: __MODULE__.UserSupervisor, strategy: :one_for_one}
    ]

    # PR #141 (SPEC v2): identity domain owns the User Kind, so it
    # registers an initial `entity://` spawn fn that handles `host =
    # "user"`. The chat plugin (which boots later — chat depends on
    # identity) OVERWRITES this registration with a combined fn that
    # additionally handles `host = "agent"` (PR #149 — snapshot /
    # template / flavor-prefix resolver; `Ezagent.AgentTypeRegistry`
    # was deleted). This layering keeps identity self-sufficient for
    # stacks that don't load chat (e.g. CLI-only test contexts).
    case Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__) do
      {:ok, sup_pid} ->
        :ok = register_user_only_entity_spawn_fn()

        # PR-M (Allen 2026-05-20) — DB write skipped in :test env to
        # avoid Sandbox checkout contention. Tests that need the admin
        # row can call `Ezagent.Users.create(admin_uri, nil,
        # MapSet.to_list(SystemPrincipal.caps("system://bootstrap")))` in setup. Dev/prod see
        # the seed on every boot (idempotent).
        :ok = maybe_ensure_admin_user()
        _ = maybe_seed_smtp_config()

        # PR-A (Allen 2026-05-23) seeded a `default` non-admin operator
        # user under the `default` workspace; SPEC v2 PR-C (#295)
        # deleted that workspace, and SPEC v2 PR-F (this PR) deletes the
        # now-dead callsite + stub. Regular users land in their email-
        # domain workspace via the onboarding LV (PR-B); CapBAC paths
        # are exercised by the per-test non-admin users tests provision
        # via `Ezagent.Users.create/3`.

        # PR-M (Allen 2026-05-20) — test-env eager admin User Kind
        # spawn. Identity boots BEFORE chat, so spawning admin here
        # preserves the previous "admin alive at boot" guarantee that
        # ~10 tests assert against (chat_routing_test, ApplicationTest,
        # snapshot tests, invocation tests). Done via the user-only
        # entity:// spawn fn we just registered — same path the chat
        # plugin will (post-overwrite) route through.
        #
        # NOTE: this preserves the OLD timing (admin spawn during
        # identity.start), so the DB read for snapshot init happens at
        # the same boot stage as before. Moving it to chat.start
        # creates Sandbox connection contention with the test's
        # subsequent Sandbox.checkout. The constraint is timing, not
        # the spawn itself.
        :ok = maybe_seed_admin_kind_for_tests()

        {:ok, sup_pid}

      other ->
        other
    end
  end

  defp maybe_ensure_admin_user do
    if test_env?() do
      :ok
    else
      ensure_admin_user()
    end
  end

  # Auto-seed SMTP from a credential file on boot so a fresh / reseeded env
  # (dev reseeds each E2E) has email (magic-link login) working without a
  # manual admin step. Idempotent: writes ONLY when smtp isn't already
  # configured AND `<credentials>/smtp_config.json` exists. The file itself is
  # seeded from the read-only /secrets mount by the docker entrypoint, mirroring
  # how feishu.yaml is seeded. Never crashes boot.
  defp maybe_seed_smtp_config do
    path = Path.join(Ezagent.Home.path(:credentials), "smtp_config.json")

    with false <- Ezagent.AppSettings.smtp_configured?(),
         {:ok, body} <- File.read(path),
         {:ok, %{} = cfg} <- Jason.decode(body) do
      Ezagent.AppSettings.put("smtp_config", cfg)
    else
      _ -> :ok
    end
  rescue
    e ->
      require Logger
      Logger.warning("SMTP auto-seed skipped: #{inspect(e)}")
      :ok
  end

  defp maybe_seed_admin_kind_for_tests do
    if test_env?() do
      # Mimic the pre-PR-M static child via direct DynamicSupervisor
      # call. NOT through SpawnRegistry — SpawnRegistry.spawn triggers
      # extra DB lookups (KindSnapshot.get) for entity URIs that
      # interact poorly with the test SQLite Sandbox boot-time setup.
      # This is the minimal-diff preservation of the pre-PR-M timing
      # + side-effects.
      admin_uri = User.admin_uri()

      # V1 prevention (Allen 2026-05-21): route via Ezagent.Kind.spawn/2.
      # User Kind declares `EzagentDomainIdentity.Application.UserSupervisor`
      # via supervisor/0 — destination preserved.
      # SPEC caps-cleanup-v1 §4.4 — admin's bootstrap caps now come
      # from `Ezagent.SystemPrincipal.caps/1` (closed Catalog, granted
      # by `system://bootstrap`), not the deleted `User.admin_caps/0`.
      case Ezagent.Kind.spawn(User, %{
             uri: admin_uri,
             initial_caps: Ezagent.SystemPrincipal.caps("system://bootstrap")
           }) do
        {:ok, _pid} ->
          :ok

        {:error, {:already_started, _pid}} ->
          :ok

        {:error, reason} ->
          require Logger

          Logger.warning(
            "maybe_seed_admin_kind_for_tests: start_child failed (#{inspect(reason)}); " <>
              "tests asserting on boot-time admin Kind may fail"
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

  # PR-M (Allen 2026-05-20) — idempotent admin User DB row provisioning
  # via the standard `Ezagent.Users.create/3` API. Same path the
  # `mix ezagent.user.create` task uses; same path every non-admin user
  # uses. No static supervisor child anymore — the User Kind spawns
  # lazily via SpawnRegistry on first dispatch reference.
  #
  # Idempotency: skip if a row already exists. Treat DB-unavailable as
  # `:ok` (boot-time tolerance, same as workspace loader) — the row will
  # be re-attempted on next boot once DB is reachable.
  #
  # `password: nil` matches `mix ezagent.user.create <uri>` without
  # `--password`: the row exists but login is refused until
  # `mix ezagent.user.set_password` is run. This preserves the existing
  # "operator sets password before first login" UX (Spec 05 Q-MU-1).
  defp ensure_admin_user do
    admin_uri = User.admin_uri()

    if Code.ensure_loaded?(Ezagent.Users) and
         function_exported?(Ezagent.Users, :get_by_uri, 1) do
      try do
        case Ezagent.Users.get_by_uri(admin_uri) do
          nil ->
            # SPEC caps-cleanup-v1 §4.4 — bootstrap caps come from the
            # closed Catalog via `Ezagent.SystemPrincipal`.
            admin_cap_list =
              "system://bootstrap"
              |> Ezagent.SystemPrincipal.caps()
              |> MapSet.to_list()

            case Ezagent.Users.create(admin_uri, nil, admin_cap_list) do
              {:ok, _decoded} ->
                :ok

              {:error, reason} ->
                require Logger

                Logger.warning(
                  "ensure_admin_user: create failed (#{inspect(reason)}); " <>
                    "admin URI bootstrap still usable via SystemPrincipal but " <>
                    "mix ezagent.user.set_password will fail until row exists"
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
            "ensure_admin_user: DB unavailable at boot (#{inspect(e.__struct__)}); " <>
              "admin row provisioning deferred to next boot"
          )

          :ok
      end
    else
      :ok
    end
  end

  defp register_user_only_entity_spawn_fn do
    :ok =
      SpawnRegistry.register("entity", fn uri ->
        case uri.host do
          "user" ->
            # SPEC caps-cleanup-v1 §4.4 — admin's bootstrap caps come
            # from `Ezagent.SystemPrincipal` (closed Catalog). Non-admin
            # users have their caps hydrated from `users.caps_json` (the
            # durable bootstrap record written by `Ezagent.Users.create/3`)
            # so EVERY demand-spawn path (mix tasks, LV admin
            # `Behavior.WorkspaceUserAdmin.create_user`, login-mediated
            # `Entity.ensure_spawned/1`) lands the same cap set into the
            # User Kind's `:identity` slice — independent of which spawn
            # entry point ran first.
            #
            # Pre-fix (wildcard-cap-fix regression, 2026-05-26): non-admin
            # users defaulted to `MapSet.new()`, so a `mix ezagent.user.create`
            # that wrote a wildcard cap to `caps_json` produced a slice
            # WITHOUT that wildcard — the slice was snapshotted in the
            # default-only state, and `Kind.Snapshot.load_or_init/3`
            # then preferred snapshot over `args[:initial_caps]` on every
            # subsequent boot. The wildcard never reached dispatch step
            # 5.5's `holds_cap?` lookup. PR-CC-2-v2 (#354) + #358
            # unmasked this by removing the transitional bridge that
            # was masking the divergence for `system://` principals.
            initial_caps = User.initial_caps_for_spawn(uri)

            # V1 prevention (Allen 2026-05-21): route via Ezagent.Kind.spawn/2.
            Ezagent.Kind.spawn(User, %{uri: uri, initial_caps: initial_caps})

          other ->
            {:error, {:no_entity_host_handler, other}}
        end
      end)

    :ok
  end

  defp register_identity_behaviors do
    for action <- Identity.actions() do
      :ok = CapabilityRegistry.register(User, action, Identity)
      # Agent identity-cap binding stays here too — Agent Kind belongs
      # to chat plugin but identity actions on it are an Identity
      # concern. Both apps load before plugins start dispatching, so
      # registering against Ezagent.Entity.Agent here is safe even though
      # Agent is defined in ezagent_domain_instance_message.
      :ok = CapabilityRegistry.register(Ezagent.Entity.Agent, action, Identity)
    end

    # PR-OWN-3 (caps-data-ownership SPEC #306 §7): register the
    # split-out `IdentityAdmin` Behavior (cap-only, privileged
    # actions). Registered against the same Kinds as `Identity`
    # since both share the `:identity` slice.
    for action <- Ezagent.Behavior.IdentityAdmin.actions() do
      :ok = CapabilityRegistry.register(User, action, Ezagent.Behavior.IdentityAdmin)

      :ok =
        CapabilityRegistry.register(
          Ezagent.Entity.Agent,
          action,
          Ezagent.Behavior.IdentityAdmin
        )
    end

    # Allen 2026-05-26 — ApiKeys flipped from User Kind to Agent Kind.
    # Agents hold their OWN outbound credentials (the credential funds
    # the agent's outbound HTTP call, not the user's). Cross-domain
    # registration like Identity above: the Behavior module lives in
    # identity domain; the Agent Kind lives in chat domain. Both apps
    # load before plugins start dispatching, so registering against
    # `Ezagent.Entity.Agent` here is safe.
    for action <- ApiKeys.actions() do
      :ok = CapabilityRegistry.register(Ezagent.Entity.Agent, action, ApiKeys)
    end

    # HIGH-2 completion (2026-05-26): UserCredentials Behavior — the
    # dispatch-backed `:set_password` action that replaces the legacy
    # `mix ezagent.user.set_password` direct call into
    # `Ezagent.Users.set_password/2`. Registered ONLY on User Kind
    # (Agent Kinds don't have passwords).
    for action <- UserCredentials.actions() do
      :ok = CapabilityRegistry.register(User, action, UserCredentials)
    end

    # HIGH-2 completion (2026-05-26): UserTokens Behavior — the
    # dispatch-backed `:mint_token` / `:list_tokens` / `:revoke_token`
    # actions that replace the legacy `mix ezagent.user.token --mint/
    # --list/--revoke` direct calls into `Ezagent.Entity.Token.*`.
    # Bootstrap-mint carve-out STAYS in the legacy task per codex
    # PR #304 MED finding. Registered ONLY on User Kind (Agent tokens
    # are still minted via the legacy task — there's no LV path for
    # them to model after yet).
    for action <- UserTokens.actions() do
      :ok = CapabilityRegistry.register(User, action, UserTokens)
    end

    # Codex PR #356 r1 CRIT fix (2026-05-26): split `:create_user`
    # from `Behavior.Workspace` into its OWN Behavior on Workspace
    # Kind so the cap shape is distinct. Without this, any holder of
    # a `Behavior.Workspace` cap (e.g. `:add_member`) would ALSO be
    # authorized for `:create_user` and could mint users with
    # arbitrary caps. Registered cross-domain because the action body
    # wraps `Ezagent.Users.create/3` from the identity domain.
    for action <- WorkspaceUserAdmin.actions() do
      :ok = CapabilityRegistry.register(Ezagent.Entity.Workspace, action, WorkspaceUserAdmin)
    end

    # CapabilityRegistry SPEC rev 4 §5 — register User.default_caps/1
    # with the registry so /admin/caps + future audit can enumerate
    # "what does a fresh User get in this workspace". The function
    # stays as-is in `Ezagent.Entity.User`; existing callers
    # (`Users.create/3`, Feishu `BindingPolicy.ensure_user_default_caps/2`,
    # `mix ezagent.stress`, tests) continue to call it directly.
    :ok = CapabilityRegistry.register_default_grant(User, &User.default_caps/1)

    :ok
  end
end
