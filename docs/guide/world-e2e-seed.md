# World plugin — local E2E seed + dev server recipe

A reusable recipe for visually verifying the `ezagent_plugin_world` conversation
surface (members panel, @mention autocomplete, composer) with agent-browser on an
isolated home. Used by every world migration PR's visual E2E and by completion
criterion #4 of the LV→world parity work.

## Why a seed is needed

The conversation read-path (`Ezagent.World.ConversationData.member_options/1` →
`Ezagent.Kind.get_slice/2`) reads the session's **live** slice. A brand-new home
has no joined members, so the members panel and @mention dropdown render empty.
The seed creates a known session with two joined members so those surfaces have
real data to show. Membership is persistent (`Ezagent.Entity.Session` uses
`{:snapshot, :on_change}`), so seeding once and restarting the server is enough —
opening the conversation **self-joins** the viewer, which lazily re-spawns the
session from its snapshot and surfaces the persisted members.

## 1. Seed (server STOPPED)

Run with the dev server stopped to avoid the two-BEAM SQLite trap. The script is
idempotent.

```bash
cd <repo>                       # or the worktree you're developing in
lsof -ti :4020 | xargs kill -9  # stop phx if running
lsof -ti :5175 | xargs kill -9  # stop vite if running

EZAGENT_HOME=/tmp/ezagent_pr1_e2e mix run scripts/world_e2e_seed.exs
```

This seeds, into `session://system/default/main`:
- users `entity://system/user/alice` and `entity://system/user/bob`, each with a
  narrow per-session `:join` + `:send` cap, joined to the session;
- the admin login email (`WORLD_E2E_ADMIN_EMAIL`, default `admin@ezagent.chat`)
  and password (`WORLD_E2E_ADMIN_PW`, default `worlddev`) so the browser can
  sign in through the email+password login form.

The script prints the `?session=` deep-link.

## 2. Start the dev server

```bash
EZAGENT_HOME=/tmp/ezagent_pr1_e2e PORT=4020 PHX_HOST=0.0.0.0 WORLD_VITE_PORT=5175 \
  mix phx.server
```

phx starts its own vite watcher on `WORLD_VITE_PORT`. If you see
`Port 5175 is already in use`, a stale vite is holding it — kill both ports
(step 1) and restart phx so it manages a single fresh vite (avoids serving stale
bundles).

## 3. agent-browser (login + verify)

The world UI is host-routed on `world.ezagent.chat`, so map it to localhost at
browser launch. Cookies are per-browser-session; if redirected to `/login`, sign
in again. The login form's first `<input>` is the hidden `_csrf_token` — fill the
two **visible** inputs (`entity_uri`, `secret`):

```bash
SESSION=world-pr3   # any stable session name
B="agent-browser --session $SESSION"

$B --args "--host-resolver-rules=MAP world.ezagent.chat 127.0.0.1" \
   open "http://world.ezagent.chat:4020/login"

# fill the two VISIBLE inputs and submit (skip the hidden _csrf_token)
$B eval "var f=document.forms[0]; var v=[...f.querySelectorAll('input')].filter(i=>i.type!=='hidden'); var s=Object.getOwnPropertyDescriptor(HTMLInputElement.prototype,'value').set; s.call(v[0],'admin@ezagent.chat'); v[0].dispatchEvent(new Event('input',{bubbles:true})); s.call(v[1],'worlddev'); v[1].dispatchEvent(new Event('input',{bubbles:true})); f.submit();"

$B open "http://world.ezagent.chat:4020/sessions?session=session%3A%2F%2Fsystem%2Fdefault%2Fmain"
$B screenshot /tmp/world-members.png
```

The members panel should show `admin`, `alice`, `bob`.

## Gotchas (learned the hard way)

- **`pkill -f "PORT=4020"` does not match** — the env var isn't in the process
  argv. Kill by port: `lsof -ti :4020 | xargs kill -9`.
- **Do not seed while the server runs** — two BEAMs on one SQLite file corrupts
  /locks. Stop phx first.
- **agent-browser `--args` is a launch flag** — ignored if a daemon is already
  running. `agent-browser close` first if you need to change launch args.
- **React-controlled inputs** ignore `fill`/`type` — set the value via the native
  setter + dispatch an `input` event (as the login snippet does).
