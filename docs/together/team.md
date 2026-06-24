# Dev Together Team

_Last checked: 2026-06-24_

The durable roster for `dev-together`. **Row identity = `github_username`** (the
canonical key; it joins to PR authorship). `dev-together plan` reads this file,
filters to `role: human-dev`, and derives each dev's next increment from
`current_track` + `latest_return`. `current_track` / `latest_return` have a
**single writer: `dev-together review`** (end of day). A mid-stream pivot may be
reflected by the lead.

`short_name` is the alias the daily `plan.md`/handoffs use (`zyli`, `zhaomato`);
it exists so the long GitHub key joins to the short name plans cite.

| github_username | short_name | role | feishu_name | current_track | latest_return | timezone | github_lookup |
|---|---|---|---|---|---|---|---|
| `zyli-developer` | zyli | human-dev | 李震宇 | 人肉 full-flow validation (was world-deploy-e2e-pg) | `2026-06-23/returns/world-deploy-e2e-pg.md` | GMT+8 | verified org member |
| `gagameow` | gaga | human-dev | 黄佳佳 | agent-config backend (`feat/agent-config-backend`, #84 后端契约) — cc-headless DONE (#931) | `2026-06-24/returns/cc-headless-real-implementation.md` | GMT+8 | verified |
| `zhaomaota97` | zhaomato | human-dev | 张宁 | 官网 (official website, on the @json-render substrate) | `2026-06-23/returns/world-hello-convergence.md` | GMT+8 | verified org member |
| `FatNine` | fatnine | human-dev | 戴明 | #84 Agent Console CRUD | `2026-06-22/returns/agent-console.md` | GMT+8 | verified |
| `allenwoods` | allen | lead | 林懿伦 | dev-together lead (plan/handoff/close/review) + own tracks | n/a | GMT+9 | verified |
| `jjkysy` | jjkysy | human-dev | 姚升悦 | (no active track) | n/a | GMT+8 | verified |
| `ruihuachen-designer` | ruihua | designer | 陈瑞华 | (no active track) | n/a | GMT+8 | verified |
| `claude` | claude | agent | — | off-plan support (orchestration / fixes on request) | n/a | — | n/a |
| `codex` | codex | agent | — | off-plan support (bounded verifiable sub-tasks) | n/a | — | n/a |

> **role legend:** `human-dev` gets a daily track in `plan`. `lead` runs the
> cadence. `agent` is off-plan support — never gets a track row in the plan.
> `designer` / others are listed for the username↔Feishu map but get no track.
