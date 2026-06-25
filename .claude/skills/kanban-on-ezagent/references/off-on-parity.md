# off ↔ on parity — the two skills are usage-identical

`kanban-off-ezagent` (file board) and `kanban-on-ezagent` (live ezagent board) run
the **same product workflow**. Only the **board medium** differs: a markdown file
vs. a live kanban Kind read/written by dispatch. Everything a user does — the
states, the links, the node ids, the 8 commands, the roles — maps **1:1**. This
table is the proof; following either column lands you in the same place.

## Core medium mapping
| concept | off-ezagent (file) | on-ezagent (live) |
|---|---|---|
| **The board** | one `docs/board.md` markdown file | one kanban Kind at `resource://<ws>/kanban/<name>` |
| **Where state lives** | bytes on disk | the Kind **snapshot** (durable, multi-writer) |
| **Read the board** | open/parse `docs/board.md` | dispatch `get_tree` (live-board-access.md §24-action) |
| **Write the board** | edit `docs/board.md` lines | dispatch a mutating `kanban.*` action |
| **Create the board** | `scripts/new_board.sh` once at product start | dispatch `get_tree` to a fresh URI → ReadyGate auto-spawns the Kind |
| **Markmap view** | the file *is* markmap (headings = tree) | dispatch `export_markmap` → markmap markdown |
| **Cross-tool sync** | paste the markmap into XMind / GitHub by hand | dispatch `sync_github` / `sync_miro` / `sync_prs` |
| **Per-day log (same on both)** | `docs/together/<date>/` | `docs/together/<date>/` — identical |

## Node model mapping (identical — same field names + values)
| node field | off (`board.md` blockquote) | on (Kind snapshot, `kanban.ex:13-24`) |
|---|---|---|
| `stage` | `> stage: positioning` (9-chain) | `stage: :positioning` (`@stages`, `kanban.ex:38`) |
| `owner` | `> owner: alice@acme` / `—` | `owner: user_uri \| agent_uri \| nil` — **on also allows an agent URI** |
| `status` | `> status: doing` (4-state) | `status: :doing` (same 4-state) |
| `artifact` | `> artifact: tool=… kind=… ref=… url=…` | `%{tool,kind,ref,url,content}` |
| `metric` | `> metric: name=… target=… current=… unit=…` | `%{name,target,current,unit}` |
| node id | the heading's position in the tree | `"n<seq>"` returned by `add_node` (`kanban.ex:302`) |
| **the `url`** | the link written in the file | the link stored on the live node | **same link both sides** |

The off `board-format.md` says outright it mirrors `kanban.ex` §15-19 "exactly —
same names, same legal values", so this row-for-row equality is by construction, not
coincidence.

## Command mapping (same 8, same role, file-action ↔ dispatch)
| # | command | off action (file) | on action (dispatch) |
|---|---|---|---|
| 1 | `init` | `new_day.sh` + confirm `board.md` exists | scaffold day folder + `get_tree` once (auto-spawn) |
| 2 | `plan` | read `board.md`, classify nodes | dispatch `get_tree`, classify nodes |
| 3 | `handoff` | add a heading + blockquote for stage N+1, `owner: —` | dispatch `add_node` for stage N+1 (left unclaimed) |
| 4 | `dive` | edit node `owner:`/`status: doing` in the file | dispatch `claim_node` + `set_status doing` |
| 5 | `return` | edit node status/artifact lines + write `returns/` | dispatch `set_status`/`attach_artifact`/`set_metric` + write `returns/` |
| 6 | `push` | order returns → `stack.md` | order returns → `stack.md` (identical; no board write) |
| 7 | `close` | merge to `main` + edit node + attach link | merge to `main` + dispatch `set_status`/`set_stage`/`attach_artifact` + `sync_github` |
| 8 | `review` | re-read `board.md`, fix drift | dispatch `get_tree`, fix drift by dispatch; `export_markmap`/`sync_miro` |

## Rule mapping (the ledger rules are the same; only "how the write happens" changes)
| rule | off wording | on wording |
|---|---|---|
| No empty plan | every task lists its **board node** | every task lists its **live board node id** (from `get_tree`) |
| Timestamp every return | `returned_at` + board node + progress | `returned_at` + board node id + **progress dispatched** |
| Reconcile the whole ledger | `push` accounts for every return | identical |
| Close PR state | every PR merged/closed; node reflects outcome | identical + `sync_github`/`sync_prs` keep GitHub honest |
| Board write-back per-action | edit `board.md` immediately (mirrors the live board's per-action dispatch) | **dispatch** the mutating action immediately |

Note the off skill's write-back rule literally says it is *"mirroring the live
board's per-action dispatch"* — i.e. the file skill was written to imitate **this**
on skill's dispatch semantics. The on skill is the original; the off skill is the
file emulation.

## Validation mapping (the same two layers)
| layer | off enforces | on enforces |
|---|---|---|
| tree well-formed | `validate_skill.sh` awk over `#` headings = markmap parse | `import_markmap` runs `Markmap.parse` (`kanban.ex:623`) |
| stage relay (相邻棒) | awk: child stage = parent or next | `stage_fits?` in the Kind (`kanban.ex:439-462`) |
| field legality | awk: status ∈ 4-state | `parse_enum` in the Kind (`kanban.ex:497,736-743`) |

Off re-implements in a script what on enforces in the Behavior — same two layers,
same 9-chain, same 4-state. A board exported from on (`export_markmap`) passes the
off validator; a file board passes into on via `import_markmap`.

## The one thing on adds (the superpower)
The only thing on can do that off cannot: a node `owner` can be an **agent entity
URI**, because every mutation is an authenticated dispatch carrying `ctx.caller`
(`kanban_actions.ex:321-327`) and the Behavior checks `caller == owner` without
caring whether the principal is a person or an agent
(`kanban.ex:715`/`Shared.owner_or_admin?`). So the relay chain can run on agents, and
a kanban-manager agent can drive the whole board from chat (see
agent-orchestration.md). On a file board there is no caller and no live principal, so
this is structurally impossible off-ezagent.
