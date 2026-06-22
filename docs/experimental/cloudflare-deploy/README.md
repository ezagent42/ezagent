# Cloudflare deployment experiment (#65)

Date consolidated: 2026-06-22
Source branch: `cf/workers-deploy`
Source worktree: `/Users/h2oslabs/Workspace/esr-ng/.worktrees/cf-deploy`

This directory preserves the useful research and test artifacts from the
Cloudflare deployment spike branch. It is reference material only. It is not a
production deployment plan, and nothing here should be treated as a cutover
procedure for `app.ezagent.chat` or `dev.ezagent.chat`.

## What the branch contained

The relevant Cloudflare commits were:

- `f1c46423` - added the Cloudflare deployment plan and toy Worker scaffold.
- `3551a2e9` - locked the early deployment decisions: run the existing BEAM
  Docker image on Cloudflare Containers, route through a thin Worker first, and
  defer Pages.
- `acb838a1` - verified the toy Worker through `workers.dev` and
  `toy.ezagent.chat`.
- `d716fce5` - added the first D1/Container storage handoff.

The branch also had untracked research artifacts:

- `docs/superpowers/notes/2026-06-21-cf-container-storage-research.md`
- `docs/superpowers/handoffs/2026-06-21-cf-container-storage-research-codex-to-claude-handoff.md`
- `scripts/cf_storage_libsql_spike.exs`

Those files superseded part of the earlier Postgres-first conclusion.

## Current conclusion

Cloudflare Workers alone cannot run the Phoenix/BEAM application. The viable
Cloudflare shape is:

1. Build the existing Phoenix/BEAM Docker image for `linux/amd64`.
2. Run it on Cloudflare Containers.
3. Put a thin Worker in front of the container.
4. Use only throwaway subdomains during spikes.
5. Keep the existing `app.` and `dev.` cloudflared tunnels untouched until a
   later cutover is explicitly approved.

The toy Worker proved Cloudflare auth/deploy/custom-domain wiring only. It did
not prove the BEAM app, LiveView, WebSockets, storage, or cutover behavior.

## Storage conclusion

The storage decision changed during the spike.

Earlier handoff state:

- D1 was rejected as the app Repo because it is exposed through Worker bindings
  and HTTP APIs, not a mature Elixir `DBConnection`/Ecto adapter.
- Plain SQLite inside a Cloudflare Container was rejected because container disk
  is ephemeral.
- Managed Postgres plus R2 was initially recommended.

Later override:

- Prioritize self-host simplicity.
- Do not default to Postgres unless the SQLite-family path fails with concrete
  evidence.

Recommended next storage path:

1. Spike `ecto_libsql` / libSQL / Turso first.
2. Preserve a dual-mode story:
   - self-host/default: local SQLite-family single-file deployment;
   - Cloudflare Container: remote libSQL/Turso, preferably embedded replica if
     startup resync and ephemeral cache behavior are acceptable.
3. Keep Litestream/R2 as backup or disaster recovery support, not as the only
   acknowledged durability boundary for writes.
4. Keep managed Postgres as the fallback if libSQL adapter maturity, migrations,
   concurrency, or app compatibility fail.

Known libSQL caveat from the toy spike: `ecto_libsql` compiled against Ecto 3.14
with an `insert/8` callback warning. This repository was on Ecto 3.13.x at the
time, but adapter maturity remains the top risk.

## Preserved artifacts

- `cf-toy-worker/src/index.js` - minimal Worker used to prove deploy and custom
  domain wiring.
- `cf-toy-worker/wrangler.jsonc` - toy Worker wrangler config for
  `toy.ezagent.chat`.
- `spikes/cf_storage_libsql_spike.exs` - small Ecto/libSQL spike script.

Do not commit or preserve `.wrangler/` output, Cloudflare tokens, or account
specific secrets in this directory.

## Verified toy evidence from the branch

Toy Worker:

- Published as `ezagent-cf-toy.<account>.workers.dev`.
- Served on the custom domain `toy.ezagent.chat`.
- Did not touch the existing `app.` or `dev.` DNS records or tunnels.

libSQL local-file toy:

```sh
env MIX_INSTALL_DIR=/private/tmp/cf-libsql-mix-installs \
  elixir scripts/cf_storage_libsql_spike.exs
```

Observed output in the handoff:

```text
mode=local_file
db_path=/private/tmp/cf-libsql-spike.db
rows_after_repo_restart: [["boot", "spike-1782058454517", "2026-06-21 16:14:14"]]
```

What this proved:

- `ecto_libsql` could load in the local environment.
- Ecto SQL could create a table.
- Transactional write worked for the toy table.
- Repo stop/restart could read the row back from the local DB file.

What it did not prove:

- Remote Turso/libSQL durability.
- Embedded replica recovery after deleting ephemeral local disk.
- Real `EzagentCore.Repo` compatibility.
- Phoenix LiveView/WebSocket behavior through Worker -> Container.
- Cloudflare Container cold-start, sleep, or connection pool behavior.

## Recommended next spike

1. Run a real remote libSQL/Turso test using
   `spikes/cf_storage_libsql_spike.exs`:

   ```sh
   env MIX_INSTALL_DIR=/private/tmp/cf-libsql-mix-installs \
     LIBSQL_SPIKE_URI=libsql://... \
     LIBSQL_SPIKE_AUTH_TOKEN=... \
     LIBSQL_SPIKE_SYNC=true \
     elixir docs/experimental/cloudflare-deploy/spikes/cf_storage_libsql_spike.exs
   ```

2. Delete the local replica DB and rerun against the same remote DB to prove the
   row survives local disk loss.
3. If remote libSQL works, test a minimal real `EzagentCore.Repo` compatibility
   slice: migrations, `Repo.insert`, `Repo.insert_all`, `Repo.update`,
   transactions, JSON/map fields, arrays, constraints, and existing
   SQLite-specific migration SQL.
4. Separately spike Worker -> Cloudflare Container with the BEAM image and verify
   LiveView, Phoenix Channels/WebSockets, cold starts, and DB pool behavior.

## Hard boundaries for future work

- Do not touch `app.ezagent.chat` or `dev.ezagent.chat` during experiments.
- Do not modify existing cloudflared tunnel config as part of a spike.
- Use only new throwaway subdomains.
- Treat Cloudflare API tokens as local secrets only.
- Do not treat this directory as an executable production deploy package.
