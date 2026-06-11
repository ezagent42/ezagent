# cinnox data snapshot

- Packaged: 2026-05-29
- Source: AutoService repo @ fix/op-translate-and-cjk-orphan-leak (453975bf)
- Scope: **config + release snapshots, NO conversation/PII DB**

## Included
| Path | What |
|---|---|
| plugins/cinnox/ | souls, KB sources, references, flow_chunks, skills (L3 source) |
| runtime/sandbox/cinnox/ | slot values (customer.yaml had uncommitted edits at pack time) |
| .autoservice/sandbox/cinnox/ | sandbox admin state (incl. api_keys.json hashes, uploads) |
| .autoservice/released/cinnox/ | release snapshots v1-v11 (each contains kb/kb.db = KB index, config) |
| .autoservice/data/tenants/cinnox/ | tenant data |
| .autoservice/data/snapshots/cinnox/ | data snapshots |

## Excluded (runtime PII)
- .autoservice/database/cinnox/ : conversations.db, memory_pool.db, mock.db

Note: kb.db files under released/*/kb/ are knowledge-base indexes (config), not conversation data.
