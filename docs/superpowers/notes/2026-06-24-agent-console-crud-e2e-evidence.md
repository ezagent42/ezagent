# Agent Console CRUD — live E2E evidence (2026-06-24)

> Branch `feat/agent-console-crud` on latest `main` (incl #905 / #938 / #943).
> Live run against `mix phx.server` (PG :5432, dev DB), world UI at `world.localhost:10042`, operator `admin@ezagent.chat`.
> **Anti-demo bar:** every claim below is backed by **observed backend state** (audit log / `kind_snapshots` / `read_cascade` read-back), not a rendered form.

## Result: full CRUD proven end-to-end on the final (post-refactor) code

| Verb | UI action | Backend proof (observed) |
|---|---|---|
| **Create** | `/identities/agents/new`, flavor=echo + curl, submit | `agents.create` dispatched → workspace `session_templates` updated with the new agent → **creator manage-cap minted** (audit `cap_granted`: `cap(:agent, Manage, :any, instance: …771318)`, `granted_by entity://system/user/admin`) → push_navigate to detail |
| **Read** | open detail + config page | detail renders live Phase/Flavor/Bridge; config page renders the `read_cascade` cascade editor (curl) |
| **Update — read_cascade** | open `/identities/agents/:uri/config` (curl agent) | editor renders `advisor.behavior` key, "user layer editable" |
| **Update — apply_delta** | add field `tone=decisive`, Save | `agents.config.update {key: advisor.behavior, layer: user, patch: {tone: decisive}}` → **after a FRESH page reload, the editor shows `tone=decisive` read back from `read_cascade`** (durable, not an in-form echo) |
| **Update — delete_path** | click × on `tone` | `agents.config.delete_path` → **after fresh reload, `tone` is gone** (durable) |
| **Delete** | detail → Delete → 确认删除 | `agents.delete` → audit `…?action=manage.delete` authz **granted** → `DELETE FROM kind_snapshots WHERE uri = …190344` (Lifecycle.destroy cleared the durable snapshot) |

Screenshots captured live: the config editor showing the persisted `tone=decisive` field (the headline Update evidence) + the two-click delete confirm.

## Two findings surfaced by the live run

1. **FOUND + FIXED — missing Phoenix route (would have shipped broken).** `/identities/agents/:uri/config` 404'd live. Cause: C1 added the route to `Ezagent.World.Routes.route_for/2` + the slot registry, but **not to the Phoenix HTTP router** (`ezagent_web/router.ex`). The `routes_test` only covers `route_for/2`, so the unit test passed while the live page 404'd. Fixed in `d7d85ded` (added `live "/identities/agents/:uri/config", WorldLive`, mirroring the sibling caps/api-keys routes). **Test-gap note:** world has no `Phoenix.LiveViewTest` infra, so the HTTP-route layer is covered by this live E2E, not an automated test — see the standing "world LiveViewTest harness" follow-up.

2. **NOTE (not a bug) — the config editor requires a `ConfigEvolve`-capable flavor.** `read_cascade` dispatches `config_evolve.read_cascade`, which exists only on agents whose Kind declares `Behavior.ConfigEvolve` (= `Entity.Agent` riders: **curl**, cc-headless). On current `main`, **echo does NOT ride `Entity.Agent`** (that's #918, unmerged), so an echo agent's config page shows a **graceful** `config_error` ("配置读取失败：{:unknown_action, :read_cascade}") — no crash, no silent drop. When #918 lands, echo gains ConfigEvolve and the editor works for it too. (Minor UX follow-up: map `{:unknown_action, :read_cascade}` to a friendlier "此 flavor 暂不支持配置编辑" message.)

## Covered by unit tests (not separately re-run live)
- Delete cap-denial (no manage-cap → error surfaced, agent survives) — `agent_delete_dispatch_test.exs`.
- Delete bound-session block (lists the blocking sessions) — `agent_delete_dispatch_test.exs`.
- Config update/delete_path cap-denial reason `:unauthorized`/`:cross_workspace_denied` — `agent_config_dispatch_test.exs`.
- Create→appears-in-list + cwd-required failure — `agent_create_appears_in_list_test.exs`.

## Verdict
The Agent Console CRUD (Create / Read / Update / Delete) works against real backend state on the final code. The anti-demo bar is met: mutations are proven by durable read-backs (`read_cascade`) and `kind_snapshots` changes, not by rendered forms.
