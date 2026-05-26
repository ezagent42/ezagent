defmodule Mix.Tasks.Ezagent.User.Create do
  @shortdoc "DEPRECATED — use `mix esr workspace create_user` (HIGH-2 completion)"
  @moduledoc """
  > **DEPRECATED 2026-05-26 (HIGH-2 completion — todo.md "CLI ↔ GUI parity").**
  >
  > The dispatch-backed equivalent now exists. New callers should use
  > the auto-derived `mix esr` command, which goes through
  > `Ezagent.Invocation.dispatch/1` → step 5.5 CapBAC → audit
  > telemetry → cross-workspace iso. The structural cross-workspace
  > check now ENFORCES that the new user URI belongs to the target
  > workspace (the legacy direct-call had no such gate).
  >
  >     # NEW — preferred path:
  >     mix esr workspace create_user \\
  >         --workspace team-alpha \\
  >         --user-uri entity://user/team-alpha/allen \\
  >         --password 'temp-pw-rotate-me' \\
  >         --caps 'workspace.read,chat.send'
  >
  > This legacy task is retained for muscle memory pending operator
  > migration (the PR #355 "Feishu UserBinding" pattern). The
  > internals still call `Ezagent.Users.create/3` directly — same
  > business logic, but bypasses CapBAC + audit. New scripts should
  > switch to `mix esr workspace create_user`; this task will be
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

        mix esr workspace create_user \\
            --workspace <name> \\
            --user-uri entity://user/<name>/<handle> \\
            --password '<pw>' \\
            --caps '<cap1,cap2,...>'

    This task still works but bypasses dispatch. Will be removed in a
    future release.
    """)

    {:ok, _} = Application.ensure_all_started(:ezagent_core)
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_chat)

    {opts, positional, _} =
      OptionParser.parse(args,
        strict: [
          password: :string,
          caps: :string,
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
          mix ezagent.user.create entity://user/team-alpha/allen --password 'pw' --caps 'workspace.read,chat.send'
        """)
    end
  end

  defp do_create(user_uri_str, opts) do
    password = Keyword.get(opts, :password)
    caps_str = Keyword.get(opts, :caps, "")
    allow_allcaps = Keyword.get(opts, :allow_allcaps, false)

    with {:ok, user_uri} <- parse_uri(user_uri_str),
         :ok <- check_allcaps_flag(caps_str, allow_allcaps),
         {:ok, caps} <- Ezagent.Capability.Parser.parse(caps_str, Ezagent.Entity.User.admin_uri()),
         {:ok, decoded} <- Ezagent.Users.create(user_uri, password, caps) do
      Mix.shell().info("✓ created #{user_uri_str}")
      Mix.shell().info("  caps: #{length(caps)}")
      Mix.shell().info("  password: #{if password, do: "set", else: "NOT SET (use mix ezagent.user.set_password)"}")
      _ = maybe_spawn_user_kind(user_uri, caps)
      Mix.shell().info("  uri: #{URI.to_string(decoded.uri)}")
    else
      {:error, reason} -> Mix.raise("create failed: #{inspect(reason)}")
    end
  end

  defp parse_uri(s) when is_binary(s) do
    # Phase 9 PR-2: route through Ezagent.URI.parse!/1 so 2-segment
    # entity URIs are rejected with the SPEC v3 §3 error message.
    try do
      uri = Ezagent.URI.parse!(s)

      case uri do
        %URI{scheme: "entity", host: "user", path: "/" <> _rest} ->
          {:ok, uri}

        _ ->
          {:error, {:bad_uri, s, "expected entity://user/<workspace>/<name>"}}
      end
    rescue
      e in ArgumentError ->
        {:error, {:bad_uri, s, Exception.message(e)}}
    end
  end

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
