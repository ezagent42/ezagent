# Reproducible Hello Fusion seed

## Goal

Provide one sanctioned command that reconstructs the committed Fusion website
on a contributor's independent database. The command must not depend on the
author's database, Session snapshots, Surface state, local files, or runtime
history.

## User contract

```bash
mix ezagent.demo.seed_hello_fusion
```

The command creates or repairs:

- workspace `workspace://system`;
- public Hello Session `session://system/hello/fusion`;
- the complete website Page from
  `apps/ezagent_plugin_hello/priv/seed_page/body.json`;
- the complete website shell CSS from
  `apps/ezagent_plugin_hello/priv/seed_page/shell.css`.

After starting the web server, the reconstructed website is available at:

```text
http://localhost:10042/hello/fusion
```

## Fresh-database requirement

The primary acceptance case starts with a contributor-owned database in which
the `system` workspace, Fusion Session, and Fusion Surface do not exist. No
export, snapshot, row, token, credential, or other state from the original
author's database may be required.

The repository files `body.json` and `shell.css` are the sole website-content
seed. The command must construct all runtime and durable state through existing
sanctioned Ezagent APIs.

## Design

### Shared seed module

Add a focused `EzagentPluginHello.FusionSeed` module. It will:

1. ensure the `system` workspace;
2. call `EzagentPluginHello.App.ensure_app("system", "fusion")`;
3. read and decode the committed `body.json`;
4. read the committed `shell.css`;
5. apply the Page through `TurnDriver.drive`;
6. apply shell CSS through `TurnDriver.set_shell`;
7. return the Session URI and applied turn information.

The module will return explicit errors for missing seed files, invalid JSON,
Page write failure, and shell write failure. It will not silently fall back to
`Spec.seed()`, because a fallback would make a broken full-site seed appear
successful while producing the wrong website.

### Mix task

Add `Mix.Tasks.Ezagent.Demo.SeedHelloFusion`. The task starts the application,
calls `FusionSeed.run/0`, and prints the resulting Session URI and public URL.
It exits unsuccessfully with a readable message when the full website cannot be
applied.

### Boot-time demo seed

The existing `HELLO_DEMO_SEED=1` boot path will call the same shared module when
the configured workspace/name are `system`/`fusion`. This prevents the Mix task
and boot seed from drifting into two different Fusion pages.

The generic Hello demo seed remains available for other workspace/name pairs.

## Idempotency

Running the Fusion command repeatedly must reuse the same workspace and Session
identity. It may create a new approved Surface turn to repair or refresh the
Page, but it must not create duplicate Sessions or change the public URL.

## Security and architecture boundaries

- Use `App.ensure_app`, `TurnDriver.drive`, and `TurnDriver.set_shell`; do not
  write snapshots, Surface rows, or capabilities directly.
- Do not embed credentials, PATs, provider keys, or database-specific IDs.
- Kanban remains the board-data and permission owner; the website seed contains
  only the committed Hello product surface and its delegation entry.
- The seed is a demo/reconstruction command, not a production boot default.

## Verification

Automated tests will prove:

1. the seed succeeds when the Fusion workspace/Session is initially absent;
2. the resulting Session URI is exactly `session://system/hello/fusion`;
3. the approved Surface tree equals the committed `body.json` content;
4. shell CSS equals the committed `shell.css` content;
5. the Page contains the Hello→Kanban delegation entry and published-read UI
   contract expected by the current website;
6. a second seed run reuses the same Session identity;
7. missing or invalid seed content fails explicitly rather than producing an
   empty or basic fallback Page.

The focused Hello suite, static gates, and `mix precommit` remain the final
verification gates.
