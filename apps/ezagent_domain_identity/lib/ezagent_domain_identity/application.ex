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
  (e.g. `EzagentDomainChat.create_session("main", admin_uri)` joins admin).
  The DB row is provisioned at boot via `ensure_admin_user/0` — idempotent
  `Ezagent.Users.create/3` with `password: nil` (matches the
  `mix ezagent.user.create` flow when `--password` is omitted; first login
  requires `mix ezagent.user.set_password` first, same as any other user).
  """

  use Application

  alias Ezagent.{CapabilityRegistry, SpawnRegistry}
  alias Ezagent.Entity.User
  alias Ezagent.Behavior.{Identity, ApiKeys}

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
        # MapSet.to_list(User.admin_caps()))` in setup. Dev/prod see
        # the seed on every boot (idempotent).
        :ok = maybe_ensure_admin_user()

        # PR-A (Allen 2026-05-23) — seed a default NON-admin user so
        # dev/prod systems always have a regular-permission user to
        # exercise CapBAC paths against. Closes the "caps feel
        # invisible because everyone runs as admin" gap surfaced in
        # `docs/notes/caps-e2e-design.md` §2 reason #2.
        # Same skip-in-test rule as admin — tests create their own
        # non-admin via `Ezagent.Users.create/3`.
        :ok = maybe_ensure_default_non_admin_user()

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
      case Ezagent.Kind.spawn(User, %{uri: admin_uri, initial_caps: User.admin_caps()}) do
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
            admin_cap_list = User.admin_caps() |> MapSet.to_list()

            case Ezagent.Users.create(admin_uri, nil, admin_cap_list) do
              {:ok, _decoded} ->
                :ok

              {:error, reason} ->
                require Logger

                Logger.warning(
                  "ensure_admin_user: create failed (#{inspect(reason)}); " <>
                    "admin URI bootstrap still usable via User.admin_caps but " <>
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

  # PR-A (Allen 2026-05-23) — boot-time idempotent seed of a default
  # non-admin operator user. Same pattern as `ensure_admin_user/0`:
  #
  #   - URI: `entity://user/default/operator` (3-segment, default
  #     workspace per SPEC v3 §3 — NOT system workspace; that's
  #     admin-only territory)
  #   - Caps: `User.default_caps(workspace://default)` —
  #     workspace-scoped session caps; CANNOT cross workspaces;
  #     does NOT have admin's superset
  #   - Password: nil (operator must `mix ezagent.user.set_password`
  #     before login — same UX as admin)
  #
  # This user is what Allen will use to exercise CapBAC paths in
  # production: log in as operator, observe denial for admin-only
  # actions, observe success for workspace-scoped session actions.
  # SPEC v2 PR-C (Allen 2026-05-24) — DELETED. The `default` workspace
  # is gone; the operator user seed was a Phase 9 stop-gap to make
  # CapBAC behavior visible. Per Allen's mental model, regular users
  # land in their email-domain workspace via the onboarding flow
  # (PR-B). Boot creates ONLY admin + system workspace.
  #
  # The functions previously here:
  #   maybe_ensure_default_non_admin_user/0
  #   ensure_default_non_admin_user/0
  # are gone with this PR. Callsite at line 79 is also removed.
  defp maybe_ensure_default_non_admin_user, do: :ok

  defp register_user_only_entity_spawn_fn do
    :ok =
      SpawnRegistry.register("entity", fn uri ->
        case uri.host do
          "user" ->
            initial_caps =
              if uri == User.admin_uri() do
                User.admin_caps()
              else
                MapSet.new()
              end

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
      # Agent is defined in ezagent_domain_chat.
      :ok = CapabilityRegistry.register(Ezagent.Entity.Agent, action, Identity)
    end

    # PR #126: per-user API key storage (DeepSeek/OpenAI/etc.). Only
    # on User Kind — Agents don't own their own keys, they look up
    # the caller User's key via dispatch.
    for action <- ApiKeys.actions() do
      :ok = CapabilityRegistry.register(User, action, ApiKeys)
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
