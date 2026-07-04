# Local E2E: stand up a socialware app and verify anonymous view

Proven 2026-06-21 on `main`. The bar for sign-off is an **agent-browser
screenshot** of an anonymous visitor seeing the rendered customer page
(`feedback_esr_e2e_standards`). This recipe uses an **isolated local stack** (a
fresh `EZAGENT_HOME` + a dedicated port) — never the shared dev/prod nodes. For
the full dockerized disposable stack, see `docs/guide/dockerized-e2e.md`; the
local-isolated path below is lighter and enough for the author→public-view flow
(no Feishu / agent-reply needed).

## 0. One-time: install the customer SPA bundle deps

The customer page (`/socialware/chat`) renders the React app
`/assets/js/customer_app.js`. Its deps are declared in
`apps/ezagent_web/assets/package.json` but `node_modules` is not committed:

```bash
cd apps/ezagent_web/assets && pnpm install      # react / react-dom / sandpack
```

Without this the page is HTTP 200 but **blank** (bundle 404s).

## 1. Bootstrap an isolated home

```bash
export EZAGENT_HOME=/tmp/ezagent_sw_e2e MIX_ENV=dev
rm -rf "$EZAGENT_HOME"
mix deps.get                       # top-level, in case deps are stale
mix ezagent.home.init              # home skeleton
mix ezagent.home.adopt_db
mix ecto.create --quiet && mix ecto.migrate --quiet
```

(`mix ezagent.bootstrap` does all of this in one shot, but its internal
`deps.get` sub-phase can fail on a Hex version quirk; running the phases
directly sidesteps that.)

## 2. Seed the app + a LIVE session IN the serving node

`PublicView.public_view?/1` reads the **live** session slice, and the public
controller gates on it *before* the join that would demand-spawn the session. So
the session must be live **in the same BEAM that serves web**. Seeding in a
separate `mix run` BEAM and then starting the server leaves the session cold →
the anon visitor gets a 302.

The reliable trick on a host **without** working Erlang distribution (so no
`remsh`): run the seed in-node via `iex --dot-iex`, and keep stdin open so iex
doesn't EOF-halt and kill the server.

`seed.exs`:

```elixir
alias Ezagent.Entity.{Session, SessionTemplate}
alias Ezagent.ActionSet.Session.ConfigActions

ws = "system"
session_uri = Ezagent.URI.new!("session://#{ws}/default/swlive")

{:ok, tmpl} =
  SessionTemplate.persist_version_as_system(%{name: "sw-live", public_view: true}, ws)

case Ezagent.Kind.spawn(Session, %{uri: session_uri, behaviors: Session.socialware_behaviors()}) do
  {:ok, _} -> :ok
  {:error, {:already_started, _}} -> :ok
end

:ok = Ezagent.WorkspaceRegistry.bind(session_uri, Ezagent.Capability.workspace_of(session_uri))
{:ok, _} = ConfigActions.system_set_working_copy(session_uri, %{session_template_uri: tmpl})

IO.puts("public_view?=#{inspect(Ezagent.Socialware.PublicView.public_view?(session_uri))}")
```

Start the server with the seed loaded in-node (stdin kept open):

```bash
export EZAGENT_HOME=/tmp/ezagent_sw_e2e MIX_ENV=dev PORT=4030 PHX_HOST=0.0.0.0
nohup sh -c 'tail -f /dev/null | iex --dot-iex seed.exs -S mix phx.server' \
  > /tmp/sw_server.log 2>&1 &
mix assets.build      # builds customer_app.js + customer.css into priv/static
```

Set the admin password if you need the operator surface (genesis admin is
seeded at first boot, so run this *after* the server is up — a quick CLI write
under SQLite WAL is fine):

```bash
mix ezagent.user.set_password entity://system/user/admin --password <pw>
```

## 3. Verify the anonymous view

```bash
# server-side proof: 200 + an anon data-token
curl -s -o /dev/null -w "%{http_code}\n" \
  "http://127.0.0.1:4030/socialware/chat?session_uri=session://system/default/swlive"   # 200

# bundle resolves
curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:4030/assets/js/customer_app.js  # 200
```

Then the screenshot (the sign-off bar). For a remote user, serve on the
Tailscale IP and point the browser at `http://100.64.0.27:4030`
(`feedback_remote_browser_ip`); locally `127.0.0.1` is fine for the agent's own
capture:

```bash
agent-browser open "http://127.0.0.1:4030/socialware/chat?session_uri=session://system/default/swlive"
agent-browser screenshot /tmp/sw_anon_view.png
agent-browser snapshot     # text DOM — expect "Your conversation" / "No messages yet."
```

A correct result shows the rendered customer feed: a "Your conversation"
heading, "Live updates appear here automatically.", a message panel, and a
composer input — proving an anonymous external visitor is viewing the live
`public_view` socialware app the author created.

## Teardown

```bash
lsof -ti :4030 | xargs -r kill          # NOT pkill -f PORT=… (env vars aren't in argv)
rm -rf /tmp/ezagent_sw_e2e
```
