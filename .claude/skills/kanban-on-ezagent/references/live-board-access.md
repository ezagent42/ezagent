# Live-board access — read/write the ezagent kanban board by dispatch

The on board is a **live kanban Kind** at `resource://<ws>/kanban/<name>`. There is
no file to edit: you read and write it **only through `Ezagent.Invocation.dispatch/1`**
(P14 — dispatch is the only path between Kinds). Its state lives in the Kind's
**snapshot** (durable, multi-writer). This file is the grounded contract; every claim
below cites real code (`file:line`).

## The dispatch envelope (how every board touch is made)
Every board read/write is one dispatch. The canonical call (the world surface that
drives the live board) is `Ezagent.World.KanbanActions.act/4`
(`apps/ezagent_plugin_world/lib/ezagent/world/kanban_actions.ex:158-177`):

```elixir
target =
  Ezagent.URI.with_action(uri, :kanban, action)   # resource://<ws>/kanban/<name>?action=kanban.<action>

Ezagent.Invocation.dispatch(%Ezagent.Invocation{
  target: target,
  mode:   :call,                  # every kanban action is modes: [:call] — sync result
  args:   args,                   # e.g. %{id: "n3"} / %{parent_id: "", title: "定位稿"}
  ctx:    %{                      # the logged-in caller's identity + caps (kanban_actions.ex:321-327)
    caller: current_entity_uri,   # the user OR AGENT entity URI making the change
    caps:   current_caps,         # MapSet of caps; per-node CapBAC is judged IN the Behavior
    reply:  {:caller_inbox, self()}
  }
})
```

Grounded pieces:
- **Target URI** = `Ezagent.URI.with_action(uri, :kanban, action)` builds
  `…/kanban/<name>?action=kanban.<action>` from the canonical instance URI
  (`apps/ezagent_core/lib/ezagent/uri.ex:378-382`).
- **Resource URI** = `Ezagent.URI.resource(ws_host, "kanban", name)` →
  `resource://<ws>/kanban/<name>` (`uri.ex:457`; built in
  `kanban_actions.ex:295`).
- **mode: `:call`** — every kanban action declares `modes: [:call]`
  (`kanban.ex:46` and every `action/3` block), so the dispatch returns a synchronous
  `{:ok, result}` / `{:error, reason}`; the caller always learns the outcome (no
  fire-and-forget board write).
- **ctx.caller / ctx.caps** — the world builds ctx from the logged-in entity
  (`kanban_actions.ex:321-327`); the **per-node** authorization (`caller == owner`
  or admin) is judged **inside the Kind** by `owner_or_admin?`
  (`kanban.ex:715`, `kanban.ex:728` → `Shared.owner_or_admin?`), so the transport
  layer cannot grant access it shouldn't.

## Create the board (auto-spawn, no scaffold)
There is no `new_board.sh`. A fresh kanban URI is brought to life by **dispatching to
it**: the first `get_tree` (or any action) on a URI with no live Kind auto-spawns it
via ReadyGate. `Ezagent.World.KanbanData.board_snapshot/2` does exactly this — it
calls `ensure_spawned(uri)` then dispatches `get_tree`
(`apps/ezagent_plugin_world/lib/ezagent/world/kanban_data.ex:113-124`), and the
world's `create_kanban/2` just computes the `resource://<ws>/kanban/<name>` URI and
pushes its (auto-spawned) snapshot to the UI
(`kanban_actions.ex:281-302`). The moduledoc states the spawn-by-dispatch contract
explicitly (`kanban.ex` / `kanban_actions.ex:14-17`,
`kanban_data.ex:12`).

## The 24-action contract (from `kanban.ex`, grounded)
Every action is declared with `action/3` and handled by `handle_<action>/2`. Caps,
args, and the `modes: [:call]` are from the source. Grouped by the workflow phase
they serve:

### Read / project (what `plan` & `review` dispatch)
| action | args | returns | line |
|---|---|---|---|
| `get_tree` | `%{}` | `%{tree, drops, config, miro, github, ci}` | `kanban.ex:138`, handler `:544-561` |
| `export_markmap` | `%{}` | `%{markdown}` | `kanban.ex:146`, handler `:606-614` |
| `import_markmap` | `%{markdown}` | `%{count}` (admin) | `kanban.ex:154`, handler `:616-643` |

### Topology (what `handoff` & node edits dispatch)
| action | args | line |
|---|---|---|
| `add_node` | `%{parent_id, title}` → `%{id}` (parent_id="" = root, admin-gated) | `kanban.ex:42`, handler `:285-313` |
| `rename_node` | `%{id, title}` | `kanban.ex:50` |
| `move_node` | `%{id, new_parent_id}` (no cycles, stage monotonic) | `kanban.ex:58`, handler `:320-348` |
| `remove_node` | `%{id}` (cascade) | `kanban.ex:66` |
| `set_stage` | `%{id, stage}` (相邻棒推进 only — `stage_fits?` `:439-462`) | `kanban.ex:74`, handler `:410-431` |
| `drop_subtree` | `%{id, reason}` (graph-level drop history) | `kanban.ex:130`, handler `:370-407` |

### Claim / status (what `dive` & `return` dispatch)
| action | args | semantics | line |
|---|---|---|---|
| `claim_node` | `%{id}` | owner=caller, status→claimed; rejects if already owned | `kanban.ex:82`, handler `:469-489` |
| `unclaim_node` | `%{id}` | owner=nil, status→unassigned | `kanban.ex:90`, handler `:491-493` |
| `set_status` | `%{id, status}` | status ∈ {claimed,doing,done}; must claim first | `kanban.ex:98`, handler `:496-510` |

### Artifacts / metrics (DoD attachment)
| action | args | line |
|---|---|---|
| `attach_artifact` | `%{id, artifact}` (`%{tool,kind,ref,url,content}`) | `kanban.ex:106`, handler `:517-518` |
| `detach_artifact` | `%{id, ref}` | `kanban.ex:114`, handler `:521-527` |
| `set_metric` | `%{id, metric}` (`%{name,target,current,unit}`, upsert by name) | `kanban.ex:122`, handler `:530-537` |

### Outbound connectors (what `close`/`review` dispatch for GitHub/Miro)
| action | args → returns | line |
|---|---|---|
| `sync_github` | `%{id}` → `%{number, url}` (node → GitHub issue, re-attach issue) | `kanban.ex:169`, handler `:656` |
| `push_pr` | `%{id}` → `%{url}` (post requirement summary to the node's PR) | `kanban.ex:177`, handler `:659` |
| `register_pr` | `%{id, pr}` (record PR #, attach PR link) | `kanban.ex:185`, handler `:662` |
| `attach_code_file` | `%{id, sha, path}` → `%{url}` (github blob link) | `kanban.ex:193`, handler `:665` |
| `sync_prs` | `%{}` → `%{advanced}` (poll registered PRs; merged/closed → status done) | `kanban.ex:201`, handler `:668` |
| `sync_miro` | `%{}` → `%{board_id}` (push to Miro board) | `kanban.ex:209`, handler `:671` |
| `set_board_config` | `%{github_repo, miro_board}` | `kanban.ex:217`, handler `:674` |
| `save_github_creds` | `%{access_token, repo}` (admin) | `kanban.ex:225`, handler `:677` |
| `save_miro_creds` | `%{access_token, board_id}` (admin) | `kanban.ex:233`, handler `:680` |

That is 24 actions; the authoritative enumeration is the `required_caps/0` list
(`kanban.ex:242-271`). Each `kanban.*` action requires the matching cap
`Ezagent.Capability.cap(:kanban, Kanban, action)` (`kanban.ex:270`).

## The node model (the shape stored in the snapshot)
Every node, from `kanban.ex:13-24` (moduledoc) + `new_node/4`
(`kanban.ex:686-697`):

```
%{
  parent_id, title, order,                                       # topology
  stage:     :positioning|:metric|:pain|:anchor|:ux|:feature|:issue|:test|:pr,  # the fixed 9-stage chain
  owner:     user_uri | agent_uri | nil,                         # claimer; nil ⟺ status==:unassigned
  status:    :unassigned | :claimed | :doing | :done,            # coarse 4-state; fine status in the linked tool
  artifacts: [%{tool, kind, ref, url, content}],                 # GitHub PR / feishu doc / xmind / uploaded file
  metrics:   [%{name, target, current, unit}]                    # value/ops metric
}
```

This is **the exact same node model the off twin mirrors** in its `board.md`
blockquotes — same field names, same legal values, same artifact/metric shape (the
off `board-format.md` says so explicitly). The stage chain is fixed
(`@stages`, `kanban.ex:38`); the stage relay rule (child = parent stage or next
stage, 相邻棒推进) is enforced by `stage_fits?` (`kanban.ex:439-462`) — the same rule
the off validator re-implements.

**Invariant:** `owner == nil ⟺ status == :unassigned`
(`kanban.ex:24`, enforced across `claim`/`unclaim`/`set_status`). On both twins.

## Persistence — the snapshot, not a file
Plugin code never sees `slice` or `snapshot` directly (framework injects reads via
`ctx[:read]`; writes go through `{:set, key, value}` effects). The kanban Behavior
funnels **all** tree writes through a single `commit/1`
(`kanban.ex:704-705` → `Shared.commit/1`), and reads via `Shared.tree(ctx)`
(`kanban.ex:702`). The framework persists that committed state in the Kind snapshot,
so the board survives restarts and is shared across all callers — this is the
on-equivalent of "the file is on disk", except it's multi-writer by construction and
every write is an authenticated dispatch.

## Projections — the on-equivalent of "render the markmap file"
The off board IS a markmap file. The on board produces its projections on demand by
dispatch:
- `export_markmap` → markmap markdown string (`kanban.ex:606-614`,
  `EzagentPluginKanban.Markmap.render`). This is the byte-for-byte format the off
  `board.md` uses, so an exported on board can be saved as an off `board.md` and a
  file `board.md` can be fed back via `import_markmap` (`kanban.ex:616-643`).
- `sync_github` / `sync_prs` → GitHub issues/PR state mirrored onto nodes.
- `sync_miro` → a Miro board mirror.
- `get_tree` also returns a `ci` map (per-`pr`-node CI verdict, `kanban.ex:599-604`)
  and the live `config`/`miro`/`github` connection status (`kanban.ex:551-560`) —
  the read-side projection the UI/`review` consumes.

## Reading the result back
A read is just `get_tree` (or `export_markmap`). `KanbanData.board_snapshot/2`
(`kanban_data.ex:113-148`) shows the JSON-safe shape the world turns the
`get_tree` result into; `read_tree/2` (`kanban_data.ex:105`) is the thin "just the
tree" accessor. When you (or an agent) need the day's board state in `plan`/`review`,
dispatch `get_tree` with the leader's ctx and read `result.tree.nodes`.
