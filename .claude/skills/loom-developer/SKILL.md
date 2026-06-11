---
name: loom-developer
description: >-
  Use whenever working on the Loom plugin — touching any .ex file under
  apps/ezagent_plugin_loom/, the vendored frontend under
  priv/static/loom_ui/, the loom HTTP/SDK bridge (web_plug.ex), the loom
  agents (orchestrator / worker / v0worker / meta-agent), the LLM backends
  (claude_code / deepseek / stitch_chat), snapshots/fork/publish, or any
  docs/loom/*.md. Loom is an in-app AI-page-builder + multi-agent demo that
  rides on the ezagent runtime: a Next.js static frontend served by a single
  Plug, a per-session agent team, two swappable LLM backends, and a
  preview-side AI (Stitch/AiSpot) that ALWAYS calls DeepSeek directly. This
  skill loads the mental model, the file map, the verified gotchas Claude
  Code trips on, and how-to recipes. Trigger on any Loom contribution — the
  divergences from the generic ezagent contract are silent landmines.
---

# loom-developer

You are working on **Loom**, a plugin (`apps/ezagent_plugin_loom/`) that runs on the ezagent runtime. Loom is two things glued together:

1. **An AI-page-builder product** — a Next.js single-page frontend where a user chats to generate/edit a live React page (v0-style), publishes it as a shareable link, and where viewers of the published page get a preview-side AI assistant (Stitch) and dynamic "✨" cards (AiSpot).
2. **A multi-agent demo on top of ezagent** — each Loom session spawns a *team* of agents (orchestrator + workers + v0worker + meta-agent) that decompose → fan out → aggregate a user request.

> **This skill is a companion, not a replacement.** For the underlying runtime contract (dispatch model, CapBAC, URI SPEC, Behavior/Kind engine, invariants), you MUST still load **`ezagent-developer`** and **`elixir-phoenix-helper`**. This skill only covers what is *Loom-specific* — and where Loom **diverges** from the generic ezagent guidance.

## The one divergence that bites first

The `ezagent-developer` skill says *"`use Ezagent.Lifecycle` is the SOLE developer-facing way to author a Behavior; never write `use Ezagent.Behavior` / `init_slice` / `state_slice` / `invoke/4`."*

**Loom does NOT follow that.** Every Loom Behavior is written on the older engine surface directly:

```elixir
use Ezagent.Behavior            # NOT use Ezagent.Lifecycle
action(:receive, args: ..., returns: ..., caps: [:receive], modes: [:cast], ...)
def state_slice, do: :loom_worker
def init_slice(args), do: %{...}
def handle_receive(args, ctx), do: {:ok, result, [effects]}
def data_owner(_), do: :no_owner
```

When you edit or add a Loom Behavior, **match the surrounding Loom code** (`use Ezagent.Behavior` + `handle_<action>`), do NOT "modernize" it to `use Ezagent.Lifecycle`. If you think it *should* be migrated, that's an architecture decision for Allen — flag it, don't silently rewrite. (Reads are still `ctx[:read].(:key, default)`; writes are still the `{:set, k, v}` effect; cross-Kind sends are still `{:dispatch, %Cmd{}}`. Those parts match the generic contract.)

The full list of Loom-specific landmines is in **`references/gotchas.md`** — read it before any non-trivial change.

## How to use this skill

1. New to Loom? Read **`references/backend-map.md`** (the agent team, the LLM backends, the data stores) and **`references/frontend-and-sdk.md`** (the frontend, the SDK bridge, the build/sync flow) end to end — ~20 min, and you can navigate the whole plugin.
2. About to change code? Read **`references/gotchas.md`** first — it's the list of things that pass compile + look right and are still wrong.
3. Doing a common task (add a tool, add a worker, add an SDK endpoint, change a prompt, rebuild the frontend)? Jump to **`references/recipes.md`**.
4. Always also have `ezagent-developer` + `elixir-phoenix-helper` loaded for the runtime invariants.

| If your question is about… | File |
|---|---|
| The agent team, LLM backends, snapshots/fork, auth, tools, boot | `references/backend-map.md` |
| The frontend, SDK bridge, build→sync, Stitch/AiSpot, data lifecycle | `references/frontend-and-sdk.md` |
| "Is this safe to change / why is it like this?" | `references/gotchas.md` |
| "How do I add/change X?" | `references/recipes.md` |
| Runtime invariants (dispatch, caps, URI, persistence) | `ezagent-developer` skill |
| Elixir/Phoenix/OTP idioms | `elixir-phoenix-helper` skill |

## Mental model in 90 seconds

```
Browser  ──HTTP/loom──▶  EzagentPluginLoom.WebPlug   (the ONLY web entry; forward "/loom" in ezagent_web)
                              │
        ┌─────────────────────┼──────────────────────────────┐
        │ serves               │ /api/* SDK bridge             │ preview-side AI
        ▼                      ▼                               ▼
  priv/static/loom_ui/   Router.dispatch / legacy        DeepSeek (DIRECT — never the
  (Next.js static          Invocation.dispatch into       LLM dispatcher, never the team)
   export, basePath         the session                   ├─ Stitch chat  (/api/.../stitch)
   '/loom')                 │                              └─ AiSpot cards (/api/.../aispot)
                            ▼
                   Loom agent TEAM (per session, spawned by Team.ensure_team):
                     loomorch_<sid>     orchestrator: decompose→fan out→aggregate→compose
                     loomworker_<sid>_* workers (policy / company themes)
                     loomv0_<sid>       v0worker: the ONLY thing that edits page source
                     loommeta_<sid>     meta-agent: @-mention add/remove team members
                            │
                            ▼
                   LLM dispatcher  EzagentPluginLoom.LLM.chat/2
                     ├─ :claude_code → local `claude` headless (default)
                     └─ :deepseek    → DeepSeek HTTP
                   (boot-time switch via LOOM_LLM_BACKEND; NOT hot-swappable)
```

Three facts that explain most of the design:

- **Two LLM "planes."** The agent team's reasoning goes through the swappable `LLM` dispatcher (`claude_code` or `deepseek`). The *preview-side* AI (Stitch, AiSpot) **always** calls `EzagentPluginLoom.DeepSeek` directly — it is a separate, simpler, faster assistant and is not user-configurable. Never route Stitch/AiSpot through `LLM`. (Memory: `feedback-preview-ai-independent-deepseek`.)
- **One writer of page source.** Only the *authoring* session's `loomv0` worker can change the page source (the `:loom_orchestrator` slice's `loom_source`). Every consumer surface (published link, snapshot, fork) gets a **frozen** base and can only layer `user_schema` ops on top. Stitch never touches source — it only appends ops.
- **The frontend source is not in this repo.** Only the built static export is vendored at `priv/static/loom_ui/`. The Next.js source lives in a separate Desktop repo (`C:\Users\Ning\Desktop\loom\ai-ui-builder`). Editing files under `priv/static/loom_ui/` directly is almost always a mistake — they get overwritten on the next build→sync. See `references/frontend-and-sdk.md`.

## Project conventions that apply here

These come from the parent repo (and memory) and bite in Loom specifically:

- **Restarting `mix phx.server` costs ~4.5 min** and takes the dev server (port 10042) down. Backend `.ex` changes need a restart — **tell Allen first**. Frontend-only changes (the vendored static files) do **not** need a backend restart. Memory: `feedback-warn-before-dev-server-restart`.
- **DeepSeek key + backend switch:** `DEEPSEEK_KEY` in `.env`; `LOOM_LLM_BACKEND=claude_code|deepseek` chosen at boot via `config/runtime.exs`. Memory: `project-deepseek-key`.
- **ClaudeCode passes the prompt via stdin, not argv** — large page-gen prompts (~hundreds of KB of source) blew past `ARG_MAX` and crashed `:exec` with a call timeout. Don't "simplify" it back to argv. Memory: `project-loom-claude-prompt-via-stdin`.
- **Never bare `rm -rf $VAR/*`** when syncing the frontend; use `rsync --delete` with an explicit guarded target, or `rm -rf` of a *literal* path only. Memory: `feedback-destructive-file-ops-guardrails`.
- **Use `Ezagent.URI.new!`, not `URI.parse`**, for any session/agent URI that becomes a `chat.members` key — `URI.parse` leaves an `:authority` field and the canonical mismatch makes the same agent appear twice. (2026-06-01 demo bug.)
- **`docs/loom/*.md` are the design authority** for Loom features — each dated file is one decision/feature. Read the relevant one before changing that feature; they carry the *why*.

## When this skill conflicts with the code

Code wins. Loom moves fast and these references describe a snapshot. If a reference says a route/function exists and it doesn't (or vice-versa), trust the code and note the drift. Two known-stale spots are already called out in `references/gotchas.md` (e.g. the `POST /api/chat` route mentioned in `web_plug.ex`'s moduledoc was removed in the 2026-06-01 redesign).

## See also

- `ezagent-developer` — the runtime contract Loom sits on (load it too).
- `elixir-phoenix-helper` — Elixir/OTP/Phoenix idioms (load it too).
- `erlexec-elixir` — relevant when touching `claude_code.ex` (it drives the `claude` subprocess via `:exec`).
- `commit-work` — for commits matching the repo's Conventional Commits + Co-Authored-By style.
