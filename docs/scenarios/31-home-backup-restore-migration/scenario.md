# Scenario 31: full ezagent-home backup + restore migration

**Category**: 6 — persistence / recovery
**Status**: ✅ implemented-and-tested
**Last verified**: 2026-05-30 (home portability #120)

Bilingual lockstep mirror: [`scenario.zh_cn.md`](./scenario.zh_cn.md).

## What this proves

Copying/restoring `$EZAGENT_HOME/$EZAGENT_PROFILE/` onto another machine or a
different path **fully reconstitutes the system** — DB (users, caps, sessions,
routing rules, Kind snapshots) + the on-disk per-agent config dirs — with every
persisted absolute path rewritten to the new location.

## Pre-conditions

- A seeded ezagent home (active via `EZAGENT_HOME` / `EZAGENT_PROFILE`).
- `sqlite3` on PATH (for the `VACUUM INTO` consistency copy; a NIF
  checkpoint-then-copy fallback runs if absent).

## Actors

- **Caller**: operator running `mix ezagent.home.*` (Category A — FS/DB op
  around the runtime BEAM, like `ezagent.home.adopt_db`).

## Path-portability model (see `docs/notes/home-portability-audit.md`)

The only persisted absolute paths are the Sandbox slice's `config_dir_path`
and the `agent_config_dir`/`claude_config_dir` embedded in
`respawn_template_data` — both under `<profile_dir>/cc-agents/...`, both buried
inside `kind_snapshots.state_binary` (`term_to_binary`). `restore` decodes each
snapshot blob, rewrites the source-profile-dir prefix (read from the backup's
`MANIFEST.json`) to the target profile dir, and re-encodes. The decode is
deliberately WITHOUT the `:safe` flag — the restore task starts only
`:exqlite`, so a plugin's `template_class` atom is not in that process's atom
table and `:safe` would otherwise reject the whole blob (silently skipping the
rewrite — caught during this scenario's manual run: "rewrote 0" → "rewrote 1").

## SQLite-consistency model

`backup` copies the live DB via `sqlite3 <db> "VACUUM INTO '<dst>'"`, which
reads a single consistent transaction and writes a fresh, fully-checkpointed
file — correct even with a live `-wal`, and never touches the source files. A
backup taken while the server runs is internally consistent; stop the server
for a guaranteed-quiescent copy.

## Steps (the automated test)

`apps/ezagent_core/test/integration/home_migration_test.exs` (3 tests, green):

1. Seed throwaway home A on disk: a User snapshot with caps, an Agent Sandbox
   snapshot whose `config_dir_path` is absolute under A, a real
   `cc-agents/<ws>/<name>/.credentials.json`, a profile-level credential.
2. `Ezagent.Home.Migration.backup/1` → `.tar.gz`.
3. `Ezagent.Home.Migration.restore/4` into home B at a DIFFERENT path.
4. Boot a Repo against home B's DB; read via the NORMAL path
   (`Ezagent.Ecto.KindSnapshot.get/1` + `decode_state/1`).
5. Assert: user caps present; `config_dir_path` rewritten A→B; embedded
   `respawn_template_data` paths rewritten; `template_class`/`pty_phase`
   preserved; config-dir file content survived; rewritten path is a real dir.
   Plus: restore refuses a non-empty target without `--force`.

## Manual e2e (verified 2026-05-30, throwaway homes)

```
# Seed home A (ecto-only migrate + insert a Sandbox snapshot with an
# absolute config_dir_path under home A), then:

$ EZAGENT_HOME=/private/tmp/esr-home-test1 EZAGENT_PROFILE=default \
    mix ezagent.home.backup --out /private/tmp/esr-backup.tar.gz
✓ Backed up /private/tmp/esr-home-test1/default
  → /private/tmp/esr-backup.tar.gz

$ tar tzf /private/tmp/esr-backup.tar.gz
snapshots/  plugins/  cc-agents/team-alpha/cc_demo/.credentials.json
MANIFEST.json  db/ezagent_core.db  credentials/{cc-channels,README,feishu}...

$ mix ezagent.home.restore --from /private/tmp/esr-backup.tar.gz \
    --home /private/tmp/esr-home-test2 --profile default
✓ Restored into /private/tmp/esr-home-test2/default
  rewrote 1 snapshot path(s) to the new home

# Verify in home B's DB (raw term decode):
config_dir_path = /private/tmp/esr-home-test2/default/cc-agents/team-alpha/cc_demo
respawn agent_config_dir = /private/tmp/esr-home-test2/default/cc-agents/team-alpha/cc_demo
dir_exists = true        # the rewritten path resolves to a real restored dir
template_class = EzagentPluginCc.Template.CcAgent   # non-path field preserved
```

## Expected outcomes

- Backup is a single consistent artifact; transients (`logs/`, `pty-pids/`,
  `runtime/`) are omitted and recreated empty on restore.
- After restore, NO path under the restored home references the source home.
- The restored DB reads back identically via the production read path.

## Failure modes to test

- Non-empty target without `--force` → `{:error, {:target_not_empty, _}}`.
- Snapshot blob carrying a plugin atom not loaded in the restore process →
  must still rewrite (the `:safe`-decode regression).
- Fresh home with no DB yet → backup/restore succeed with 0 rewrites.

## Cross-references

- `docs/notes/home-portability-audit.md` — the absolute-path audit.
- `mix ezagent.home.adopt_db` / `ezagent.home.init` — sibling Category A home ops.
- `apps/ezagent_core/lib/ezagent/home/migration.ex` — the backup/restore core.
