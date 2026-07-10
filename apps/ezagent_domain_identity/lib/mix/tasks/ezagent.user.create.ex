defmodule Mix.Tasks.Ezagent.User.Create do
  @shortdoc "DEPRECATED — use `mix ezagent workspace create_user` (HIGH-2 completion)"
  @moduledoc """
  > **DEPRECATED 2026-05-26 (HIGH-2 completion — todo.md "CLI ↔ GUI parity").**
  >
  > The dispatch-backed equivalent now exists. New callers should use
  > the auto-derived `mix ezagent` command, which goes through
  > `Ezagent.Invocation.dispatch/1` → step 5.5 CapBAC → audit
  > telemetry → cross-workspace iso. The structural cross-workspace
  > check now ENFORCES that the new user URI belongs to the target
  > workspace (the legacy direct-call had no such gate).
  >
  >     # NEW — preferred path:
  >     mix ezagent workspace create_user \\
  >         --workspace team-alpha \\
  >         --user-uri entity://user/team-alpha/allen \\
  >         --password 'temp-pw-rotate-me' \\
  >         --caps 'workspace.read,chat.send'
  >
  > This legacy task is retained for muscle memory pending operator
  > migration (the PR #355 "Feishu UserBinding" pattern). The
  > internals still call `Ezagent.Users.create/3` directly — same
  > business logic, but bypasses CapBAC + audit. New scripts should
  > switch to `mix ezagent workspace create_user`; this task will be
  > removed in a future release.

  Phase 4-completion Spec 05 §A.2.1 — provision a non-admin User.

  ## Usage

      mix ezagent.user.create entity://user/team-alpha/allen \\
          --password 'temp-pw-rotate-me' \\
          --caps 'workspace.read,chat.send'

  Flags:
  - `--password <pw>` — required for login (omit only for placeholder
    rows; SessionController refuses login for password-less rows)
  - `--caps <str>` — comma-separated cap specs (see
    `Ezagent.Capability.Parser` for grammar). Default empty.
  - `--email <addr>` — bind email to the new user's `entity_profiles`
    row in the same task. Without this flag, magic-link login is
    impossible for the new user until `mix ezagent.user.set_email`
    is run separately (the 2026-05-26 v1 gap that surfaced after the
    `set_email` PR — see commit message for context).
  - `--display-name <name>` — sets the user's `display_name` in
    `entity_profiles`. Defaults to the URI path's last segment when
    `--email` is set without an explicit display name.
  - `--allow-allcaps` — required if `--caps '*'`. Prevents accidental
    admin-clones.

  ## Behavior

  1. Parses caps string via `Ezagent.Capability.Parser`
  2. Inserts row into `users` table (password bcrypt-hashed)
  3. If chat plugin is started and `entity://` spawn fn registered,
     opportunistically spawns the User Kind live (Spec 05 Q-MU-3 default)
  4. Prints confirmation + resolved cap shapes

  ## Examples

      # Read-only operator
      mix ezagent.user.create entity://user/team-alpha/qa --password X --caps 'workspace.read,chat.send'

      # Make a second admin (require explicit allow flag)
      mix ezagent.user.create entity://user/team-alpha/allen2 --password X --caps '*' --allow-allcaps
  """
  use Mix.Task

  @impl Mix.Task
  def run(args) do
    Mix.shell().info("""
    NOTE: `mix ezagent.user.create` is deprecated as of 2026-05-26.
    Use the dispatch-backed equivalent (CapBAC + audit + cross-workspace iso):

        mix ezagent workspace create_user \\
            --workspace <name> \\
            --user-uri <user-uri> \\
            --password '<pw>' \\
            --caps '<cap1,cap2,...>'

    This task still works but bypasses dispatch. Will be removed in a
    future release.
    """)

    {:ok, _} = Application.ensure_all_started(:ezagent_core)
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_session)

    {opts, positional, _} =
      OptionParser.parse(args,
        strict: [
          password: :string,
          caps: :string,
          email: :string,
          display_name: :string,
          allow_allcaps: :boolean
        ],
        aliases: []
      )

    case positional do
      [user_uri_str] when is_binary(user_uri_str) ->
        do_create(user_uri_str, opts)

      _ ->
        Mix.raise("""
        usage: mix ezagent.user.create <user_uri> [--password X] [--caps 'kind.behavior,...'] [--allow-allcaps]

        Example:
          mix ezagent.user.create <user-uri> --password 'pw' --caps 'workspace.read,chat.send'
        """)
    end
  end

  defp do_create(user_uri_str, opts) do
    password = Keyword.get(opts, :password)
    caps_str = Keyword.get(opts, :caps, "")
    email = Keyword.get(opts, :email)
    display_name_opt = Keyword.get(opts, :display_name)
    allow_allcaps = Keyword.get(opts, :allow_allcaps, false)

    with {:ok, user_uri} <- parse_uri(user_uri_str),
         :ok <- check_allcaps_flag(caps_str, allow_allcaps),
         {:ok, caps} <- Ezagent.Capability.Parser.parse(caps_str, Ezagent.Entity.User.admin_uri()),
         {:ok, decoded} <- Ezagent.Users.create(user_uri, password, caps),
         :ok <- add_workspace_membership(user_uri),
         :ok <- maybe_set_email(user_uri, email, display_name_opt) do
      Mix.shell().info("✓ created #{user_uri_str}")
      Mix.shell().info("  caps: #{length(caps)}")

      Mix.shell().info(
        "  password: #{if password, do: "set", else: "NOT SET (use mix ezagent.user.set_password)"}"
      )

      Mix.shell().info(
        "  email: #{email || "NOT SET (magic-link login unavailable until mix ezagent.user.set_email)"}"
      )

      _ = maybe_spawn_user_kind(user_uri, caps)
      Mix.shell().info("  uri: #{URI.to_string(decoded.uri)}")
    else
      {:error, reason} -> Mix.raise("create failed: #{inspect(reason)}")
    end
  end

  # 2026-07-10 golive gap — `Ezagent.Users.create/3` assigns the new
  # user's `users.workspace_uri` (derived from the entity URI) but does
  # NOT add the user to that workspace's `member_uris`. The "my
  # workspaces" view filters by MEMBERSHIP (a non-admin caller's
  # wildcard `workspace_uri: :any` caps contribute NOTHING per SPEC
  # §3.3.b), so an operator-created user was assigned a workspace they
  # could not see. This hit all 6 golive users (live-remediated via
  # `Ezagent.Workspace.add_member`). The registration/invite paths
  # already call `add_member`; this closes the operator `user.create`
  # gap so an assigned workspace ALWAYS implies membership.
  #
  # `Ezagent.Workspace` lives in `ezagent_domain_workspace`, which this
  # app does NOT compile-depend on (identity → workspace would be a
  # circular dep). So dispatch lazily via `apply/3` behind a
  # `Code.ensure_loaded?` guard — the same pattern
  # `Ezagent.Registration` uses. The workspace app IS started here
  # (`run/1` calls `ensure_all_started(:ezagent_domain_session)`, which
  # pulls in `:ezagent_domain_workspace`), so a not-loaded state means a
  # broken environment and is raised loudly, NOT silently skipped —
  # mirroring `Registration.join_under_issuer/3` (do not swallow a
  # membership failure: a user assigned to a workspace they can't join
  # is the exact bug we're fixing).
  #
  # Idempotency: `add_member/2` dedups via `Enum.uniq` on the member
  # list, so re-running `user.create` (or re-adding an existing member)
  # does not corrupt `member_uris` — proven by the regression test.
  defp add_workspace_membership(%URI{} = user_uri) do
    workspace_name = Ezagent.URI.workspace_name!(user_uri)

    cond do
      not workspace_loaded?() ->
        {:error, {:workspace_app_unavailable, workspace_name}}

      true ->
        case apply(Ezagent.Workspace, :add_member, [workspace_name, user_uri]) do
          :ok ->
            Mix.shell().info("  workspace member: added to #{workspace_name}")
            :ok

          {:error, reason} ->
            {:error, {:add_workspace_member_failed, workspace_name, reason}}

          other ->
            {:error, {:add_workspace_member_failed, workspace_name, other}}
        end
    end
  end

  defp workspace_loaded? do
    Code.ensure_loaded?(Ezagent.Workspace) and
      function_exported?(Ezagent.Workspace, :add_member, 2)
  end

  # 2026-05-26 — Allen surfaced the gap: `set_email` exists as a
  # bootstrap remediation task but `user.create` didn't accept email,
  # so every new user repeated the magic-link silent_drop bug at the
  # next login attempt. Setting email at create-time closes the loop.
  #
  # Email binding is done via the same `Ezagent.Entity.Profile.upsert/1`
  # path that `set_email` uses — keeping a single code path for the
  # email-bind operation.
  defp maybe_set_email(_user_uri, nil, _display_name_opt), do: :ok

  defp maybe_set_email(user_uri, email, display_name_opt) when is_binary(email) do
    display_name = display_name_opt || Ezagent.URI.name!(user_uri)

    profile_attrs = %{
      entity_uri: URI.to_string(user_uri),
      display_name: display_name,
      email: email,
      workspace_uri: URI.to_string(Ezagent.URI.entity_workspace_uri(user_uri))
    }

    case Ezagent.Entity.Profile.upsert(profile_attrs) do
      {:ok, _row} -> :ok
      {:error, reason} -> {:error, {:profile_upsert_failed, reason}}
    end
  end

  defp parse_uri(s) when is_binary(s) do
    # Phase 9 PR-2: route through Ezagent.URI.new!/1 so 2-segment
    # entity URIs are rejected with the SPEC v3 §3 error message.
    try do
      uri = Ezagent.URI.new!(s)

      if user_entity_uri?(uri),
        do: {:ok, uri},
        else: {:error, {:bad_uri, s, "expected entity user URI"}}
    rescue
      e in ArgumentError ->
        {:error, {:bad_uri, s, Exception.message(e)}}
    end
  end

  defp user_entity_uri?(%URI{scheme: "entity"} = uri) do
    Ezagent.URI.type?(uri, :user) and match?({:ok, _name}, Ezagent.URI.name(uri))
  end

  defp user_entity_uri?(_), do: false

  defp check_allcaps_flag(caps_str, allow_allcaps) do
    if String.contains?(caps_str, "*") and not allow_allcaps do
      {:error, :allcaps_requires_explicit_flag}
    else
      :ok
    end
  end

  defp maybe_spawn_user_kind(uri, caps) do
    if Code.ensure_loaded?(Ezagent.SpawnRegistry) do
      case Ezagent.SpawnRegistry.spawn(uri) do
        {:ok, _pid} ->
          Mix.shell().info("  spawned live User Kind at #{URI.to_string(uri)}")
          # Post wildcard-cap-fix (2026-05-26): the entity SpawnRegistry
          # fn now delegates to `Ezagent.Entity.User.initial_caps_for_spawn/1`,
          # which hydrates the User Kind's `:identity` slice from
          # `users.caps_json`. The previous "caps in DB but not in live
          # Identity slice — restart picks them up via Loader" message
          # was stale (and Loader never existed for this); caps ARE in
          # the live slice now.
          :ok = log_live_caps_count(caps)
          :ok

        {:error, reason} ->
          Mix.shell().info("  live spawn skipped: #{inspect(reason)}")
          :ok
      end
    else
      :ok
    end
  end

  defp log_live_caps_count([]), do: :ok

  defp log_live_caps_count(caps) when is_list(caps) do
    Mix.shell().info("  live Identity slice hydrated with #{length(caps)} cap(s) from caps_json")
    :ok
  end
end
