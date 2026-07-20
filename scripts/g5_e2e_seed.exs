# G5 error mechanism E2E seed — isolated stack, idempotent.
#
# Creates: 1 workspace + 2 users (founder + member) + 1 curl agent WITHOUT api key.
# The agent will fail with {:no_api_key} → G5 ErrorMatcher → Layer 1/2 cards.
#
# RUN WITH DEV SERVER STOPPED, against an isolated home:
#
#   EZAGENT_HOME=/tmp/ezagent_g5_e2e mix run scripts/g5_e2e_seed.exs
#
# Then start vite + phoenix and follow the printed instructions.

require Logger

alias Ezagent.{Capability, Invocation}
alias Ezagent.URI, as: EzUri

ws = EzUri.workspace(:system)
admin = Ezagent.Entity.User.admin_uri()

# ── Helpers ──

cap = fn member_uri, action, instance ->
  %Capability{
    kind: :session,
    behavior: Ezagent.ActionSet.Session,
    action: action,
    instance: instance,
    workspace_uri: ws,
    granted_by: member_uri,
    granted_at: DateTime.utc_now()
  }
end

issue = fn uri, caps ->
  Enum.map(caps, fn c ->
    {:ok, artifact} = Ezagent.Cap.issue({:genesis, admin}, uri, c)
    artifact
  end)
end

# ── Step 1: Create (or reuse) users ──

IO.puts("[1/4] Creating users...")

founder_uri = EzUri.new!("entity://system/user/g5-founder")
member_uri = EzUri.new!("entity://system/user/g5-member")
session = EzUri.new!("session://system/default/g5-test")

# Create session if needed
join_founder = cap.(founder_uri, :join, session)
send_founder = cap.(founder_uri, :send, session)
join_member = cap.(member_uri, :join, session)
send_member = cap.(member_uri, :send, session)

# Create users with join+send caps
for {uri, label, caps} <- [
  {founder_uri, "founder", [join_founder, send_founder]},
  {member_uri, "member", [join_member, send_member]}
] do
  case Ezagent.Users.create_read_only(uri, issue.(uri, caps)) do
    {:ok, _} -> IO.puts("  #{label}: created #{URI.to_string(uri)}")
    {:error, %Ecto.Changeset{errors: [uri: {"has already been taken", _}]}} ->
      IO.puts("  #{label}: already exists")
    other -> IO.puts("  #{label}: #{inspect(other)}")
  end

  case Ezagent.Entity.spawn_principal(uri) do
    :ok -> :ok
    {:ok, _} -> :ok
    other -> IO.puts("  spawn #{label}: #{inspect(other)}")
  end

  # Self-join the session
  result = Invocation.dispatch(%Invocation{
    target: EzUri.with_action(session, :session, :join),
    mode: :call,
    args: %{member: uri},
    ctx: %{caller: uri, caps: MapSet.new([join_founder]), reply: :ignore}
  })
  case result do
    :ok -> :ok
    {:ok, _} -> :ok
    other -> IO.puts("  join #{label}: #{inspect(other)}")
  end
end

# Set passwords
Ezagent.Users.set_password(founder_uri, "e2etest123")
Ezagent.Users.set_password(member_uri, "e2etest123")
IO.puts("  passwords set (both users: e2etest123)")

# ── Post-#1440 fix: entity_profiles + email_verified ──
# create_read_only/2 does NOT insert an entity_profiles row or set
# email_verified=true. The login flow needs both:
#   • entity_profiles.email → resolves magic-link to user URI
#   • users.email_verified → gates form login (false = blocked)
# Without these the seed users can't log in.

for {uri, email, display_name} <- [
  {founder_uri, "g5-founder@e2e.local", "G5 Founder"},
  {member_uri, "g5-member@e2e.local", "G5 Member"}
] do
  Ezagent.Entity.Profile.upsert(%{
    entity_uri: URI.to_string(uri),
    email: email,
    display_name: display_name
  })

  Ezagent.Users.mark_email_verified(uri)
  IO.puts("  #{display_name}: profile + email_verified done")
end

# ── Step 2: Create curl agent WITHOUT credentials ──

IO.puts("[2/4] Creating curl agent (no API key — will trigger {:no_api_key})...")

# Create a curl agent via system admin (has all caps)
admin_ws = Ezagent.Workspace.Store.get_by_name("system")
IO.puts("  workspace: #{URI.to_string(admin_ws.uri)}")

agent_name = "g5-e2e-agent-#{:os.system_time(:second)}"

# Issue workspace create_agent cap to admin (needed for Provisioning.create_agent dispatch)
create_agent_cap = %Capability{
  kind: :workspace,
  behavior: Ezagent.ActionSet.Workspace,
  action: :create_agent,
  instance: admin_ws.uri,
  workspace_uri: ws,
  granted_by: admin,
  granted_at: DateTime.utc_now()
}
{:ok, signed_cap} = Ezagent.Cap.issue({:genesis, admin}, admin, create_agent_cap)

{:ok, %{agent_uri: agent_uri}} = Ezagent.Workspace.Provisioning.create_agent(
  admin_ws.uri,
  %{name: agent_name, flavor: "curl", cwd: "/tmp", with_pty: false},
  %{caller: admin, caps: MapSet.new([signed_cap])}
)
IO.puts("  agent: #{URI.to_string(agent_uri)}")

# Verify NO api key is set (intentional)
IO.puts("  agent has NO api key — E2E will trigger {:no_api_key}")

# ── Step 3: Open registration ──

IO.puts("[3/4] Configuring registration...")
Ezagent.AppSettings.put("registration_open", true)
Ezagent.AppSettings.put("registration_require_invite", false)

# ── Step 4: Print instructions ──

IO.puts("""
[4/4] ✅ Seed complete!

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
G5 E2E — Manual Test Steps
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Start the server:
  EZAGENT_HOME=/tmp/ezagent_g5_e2e mix phx.server

Then in your browser (http://localhost:4000):

A / Layer 1 (founder sees fix link):
  Login: g5-founder@e2e.local / e2etest123
  → Create a session with agent "#{URI.to_string(agent_uri)}"
  → Send: "hello"
  → 📸 EXPECT: card "Agent 未配置凭证" + impact + fix link

B / Layer 2 (member sees notify button):
  Login: g5-member@e2e.local / e2etest123
  → Join the same session
  → Send: "hello"
  → 📸 EXPECT: card + "请联系 workspace founder" + "发送提醒" button

C / Layer 3 (unregistered error — any error not in registry):
  → (Requires triggering an error not registered)
  → 📸 EXPECT: "Agent 执行时遇到内部错误" + G5-... issue ID

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
""")
