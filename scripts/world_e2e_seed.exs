# World plugin E2E seed — idempotent.
#
# Seeds a known session with joined members so the world conversation surface
# (members panel, @mention autocomplete) and later write-path PRs have real
# targets to render + dispatch against. Membership is persistent state
# (`Ezagent.ActionSet.Session` moduledoc: "STATE persistent — survives restart:
# members"), so seeding once and restarting the dev server is enough — the
# members show on the cold session after boot.
#
# RUN WITH THE DEV SERVER STOPPED (two-BEAM SQLite trap), against an isolated
# home, e.g.:
#
#   EZAGENT_HOME=/tmp/ezagent_pr1_e2e mix run scripts/world_e2e_seed.exs
#
# Then start vite + phoenix and navigate to the printed ?session= deep-link.

require Logger

alias Ezagent.Capability
alias Ezagent.Invocation
alias Ezagent.URI, as: EzUri

ws = EzUri.workspace(:system)
session = EzUri.new!("session://system/default/main")

cap = fn member_uri, action ->
  %Capability{
    kind: :session,
    behavior: Ezagent.ActionSet.Session,
    action: action,
    instance: session,
    workspace_uri: ws,
    granted_by: member_uri,
    granted_at: DateTime.utc_now()
  }
end

# Decision #162 — `create_read_only/2` writes straight into `users.caps_json`,
# and the user Kind reconciles its cap slice FROM that column, so anything put
# there IS authority granted. Seeds used to hand-forge the caps and store them
# without ever calling `Cap.issue/3`, i.e. without `authorize_grant/3` running.
# Running a seed means shell access, which is admin-equivalent — so take that
# authority through the FRONT door (`{:genesis, admin}`) instead of forging
# provenance around the chokepoint. Same power, one gate.
issue = fn uri, caps ->
  admin = Ezagent.Entity.User.admin_uri()

  Enum.map(caps, fn c ->
    {:ok, artifact} = Ezagent.Cap.issue({:genesis, admin}, uri, c)
    artifact
  end)
end

ensure_member = fn uri_str, label ->
  uri = EzUri.new!(uri_str)
  join_cap = cap.(uri, :join)
  send_cap = cap.(uri, :send)

  # 1. registered user row carrying its own narrow join+send grants.
  case Ezagent.Users.create_read_only(uri, issue.(uri, [join_cap, send_cap])) do
    {:ok, _} ->
      Logger.info("seed: created user #{uri_str}")

    {:error, %Ecto.Changeset{errors: [uri: {"has already been taken", _}]}} ->
      Logger.info("seed: user #{uri_str} already exists")

    other ->
      Logger.error("seed: create_read_only #{uri_str} -> #{inspect(other)}")
  end

  # 2. spawn the principal Kind — :join requires a LIVE member
  #    (`:member_not_registered` otherwise). Returns :ok or {:ok, pid}.
  case Ezagent.Entity.spawn_principal(uri) do
    :ok -> :ok
    {:ok, _} -> :ok
    other -> Logger.error("seed: spawn_principal #{uri_str} -> #{inspect(other)}")
  end

  # 3. self-join (caller == member, member's own :join cap), mirroring the
  #    WorldConversationTest join.
  result =
    Invocation.dispatch(%Invocation{
      target: EzUri.with_action(session, :session, :join),
      mode: :call,
      args: %{member: uri},
      ctx: %{caller: uri, caps: MapSet.new([join_cap]), reply: :ignore}
    })

  case result do
    :ok -> :ok
    {:ok, _} -> :ok
    other -> Logger.error("seed: join #{uri_str} -> #{inspect(other)}")
  end

  # 4. mount the per-class participation tier (parity with Invite.ex).
  Ezagent.ActionSet.Session.Membership.mount_participation_caps(session, uri)

  Logger.info("seed: #{label} (#{uri_str}) joined #{URI.to_string(session)}")
end

ensure_member.("entity://system/user/alice", "alice")
ensure_member.("entity://system/user/bob", "bob")

# Admin login credentials for the agent-browser E2E (idempotent). Since task
# #87, the login form authenticates by email + password, so the seed must bind a
# verified email profile as well as setting a password.
admin_uri = Ezagent.Entity.User.admin_uri()
admin_email = System.get_env("WORLD_E2E_ADMIN_EMAIL") || "admin@ezagent.chat"
admin_pw = System.get_env("WORLD_E2E_ADMIN_PW") || "worlddev"

case Ezagent.Users.set_password(admin_uri, admin_pw) do
  {:ok, _} ->
    Logger.info("seed: admin password set (#{URI.to_string(admin_uri)})")

  {:error, :not_found} ->
    case Ezagent.Users.create(admin_uri, admin_pw, []) do
      {:ok, _} -> Logger.info("seed: admin user row created + password set")
      other -> Logger.error("seed: admin create -> #{inspect(other)}")
    end

  other ->
    Logger.error("seed: admin set_password -> #{inspect(other)}")
end

case Ezagent.Entity.Profile.upsert(%{
       entity_uri: URI.to_string(admin_uri),
       display_name: "Admin",
       email: admin_email
     }) do
  {:ok, _} -> Logger.info("seed: admin email bound (#{admin_email})")
  other -> Logger.error("seed: admin email bind -> #{inspect(other)}")
end

case Ezagent.Users.mark_email_verified(admin_uri) do
  {:ok, _} -> Logger.info("seed: admin email verified (#{admin_email})")
  other -> Logger.error("seed: admin email verify -> #{inspect(other)}")
end

encoded = session |> URI.to_string() |> URI.encode_www_form()

IO.puts("\n=== world E2E seed complete ===")
IO.puts("session : #{URI.to_string(session)}")
IO.puts("deep-link: /sessions?session=#{encoded}")
IO.puts("admin   : #{admin_email} / #{admin_pw}")
IO.puts("members : alice, bob (persisted; show offline until their Kinds are live)\n")
