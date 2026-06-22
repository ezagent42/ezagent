# Return — world UI beautification + product restructure (world-beautify)

- **Branch:** `world-beautify` (HEAD `67db6e79`)
- **Base:** `a6fa6db3` — **older than current `origin/main` `3790d112`**. `origin/main` is **NOT** an ancestor of HEAD → wb is **behind** main by #893 (login-with-email) + #894 (CF worker). The branch's own `stack.md` says "ff-able, zero conflict" but that was computed vs `main@a6fa6db3` and is now **STALE**: a rebase onto current main is required.
- **Author/dev:** zyli-devel
- **Task:** #83

## Scope
World UI beautification + product-structure adjustment: typed-slot registry + shadcn/Tailwind migration. Deletes the ~1650-line `world-*` `styles.css`; migrates the world surface to a shadcn foundation. Fixed an Admin CC-orchestrator raw-dump bug during verification (`6db6d876` → badge+fields).

## DoD artifact (dev-reported)
- Code-complete; gates green on its base (world suite 24/0; vite build; `check:mounts`; `world.slots.manifest --check` in sync; format).
- **Visual verification done** (human eyeball @ live world `:10042`).

## Conflict notes (lead analysis)
- **Must rebase onto current main** (login + worker landed after wb's base).
- Overlaps with **pg-compat-audit**: `world_live.ex`, `world/admin_data.ex`, `config/dev.exs`, `config/test.exs`, `per_tenant_tables_have_workspace_column_test.exs`.
- Overlaps with **main-since-base** (#893/#894): `world_live.ex`, `.gitignore`.
- `world_live.ex` is a triple-overlap (login #893 + pg CallerDisplay split + wb UI) — the most delicate conflict.
- The last 3 commits mix dev-infra (bin/dev, dev-together tooling, `.gitignore`, the day folder) into the branch — they land with #83 (dev accepted).

## world-coordination heads-up
wb **deleted** the world `styles.css` and moved to shadcn/Tailwind. Any future world UI work branched before this merge must rebase and redo styling on the shadcn base (old `world-*` BEM classes are gone). [[hello]] is already rebased onto wb, so it inherits the new base.

## Merge request
"可直接 ff 进 main" — but **stale**; lead must rebase onto post-pg main, resolve conflicts, re-run gates **under PG**, then merge.
