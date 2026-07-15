# Kanban read-only share — data-reflux is real; verify live in a real deploy env

**Context**: PR #1425 (merged) — Hello publishes a read-only reference to a Kanban board; a second Session mounts it and reads via `get_tree`.

## What is proven
- **Data reflux is real at the code/API level and is now tested.** `apps/ezagent_plugin_kanban/test/e2e/board_forward_test.exs`: after the read-only board is forwarded/mounted, the receiver's `get_tree` returns node `n1` added to the SOURCE board *after* the mount, and after the source adds `n2`, a receiver re-read sees `n2`. This fails if the mounted read ever becomes a stale copy. The receiver's `get_tree` reads the live board actor's current slice (no snapshot cache), so a stale/copied read is structurally impossible.

## What still needs a real deploy env to verify (the wall the E2E recording hit)
- **The Hello receipt UI is a delegation-time SNAPSHOT, not a live surface.** A user watching the Hello receipt does NOT see reflux; the receipt is baked at delegation time (matches the PR's own caveat: 已打开的官网回执不会实时刷新).
- **The live UI surface for a receiver is the World Kanban session tab** (re-reading there shows the latest). The disposable/mix-run stack could NOT stand this up (cc-headless flavor registry unsealed; mix-run session members don't survive respawn), so the live-UI reflux could not be screen-recorded locally.
- **TODO (real deploy env):** on a full deployed world stack, verify the receiver's World Kanban tab shows source changes on re-read (the live reflux), and record it. Separately, decide the **Hello-receipt-snapshot UX**: either auto-refresh the receipt or explicitly link the user to the live World Kanban board (so a user isn't misled by a stale receipt).
- Also untested (followup): cross-*workspace* receive denial (invariant #13); `Mount.mount`/`mint_cap` is a trusted-caller mint (any NEW caller must gate authorization itself).
