# AutoService Real E2E Scenarios and Ezagent Reproduction

Date: 2026-06-26

Source project: `/mnt/d/Work/h2os.cloud/AutoService-dev-a` (`D:\Work\h2os.cloud\AutoService-dev-a`)

Target project: `/home/huangjiajia/ezagent`

This report is based on live local execution against the AutoService working copy and its existing runtime databases. It is separate from `autoservice-e2e-scenarios-and-ezagent-mapping.md`, which is a code-analysis mapping.

## 1. What Was Actually Run

### 1.1 AutoService backend

Command:

```bash
AUTH_DEV_MODE=1 PLACEHOLDER_ENABLED=0 \
  .venv/bin/uvicorn autoservice.web_gateway:create_app \
  --factory --host 127.0.0.1 --port 8000 --log-level info
```

Observed:

- Backend reached `Application startup complete`.
- Uvicorn listened on `http://127.0.0.1:8000`.
- `cc_pool` warmed 4 main instances plus role sub-pools:
  - main pool: 4/4 warmed
  - triage pool: 1/1 warmed
  - lead pool: 1/1 warmed
- `/api/session/mode` returned 200:

```json
{
  "mode": "master",
  "tenant_id": null,
  "authenticated": false,
  "authenticated_as": null,
  "tier": null,
  "role": null,
  "brand_name": "AutoService"
}
```

### 1.2 AutoService frontend

The original Makefile defaults use ports 5173/5174/5175. Port 5173 was already occupied by the current ezagent Vite process, so the AutoService frontends were started on alternate ports after repairing Linux optional dependencies with `CI=true pnpm install`.

Commands:

```bash
pnpm --filter @autoservice/customer-chat exec vite --host 127.0.0.1 --port 5273
pnpm --filter @autoservice/operator-console exec vite --host 127.0.0.1 --port 5274
pnpm --filter @autoservice/admin-portal exec vite --host 127.0.0.1 --port 5275
```

Observed page loads:

| App | URL | Result |
|---|---:|---|
| Customer Chat | `http://127.0.0.1:5273/` | 200, title `AutoService · Customer Chat`, root div + script present |
| Operator Console | `http://127.0.0.1:5274/` | 200, title `AutoService · Operator Console`, root div + script present |
| Admin Portal | `http://127.0.0.1:5275/` | 200, title `AutoService · Admin Portal`, root div + script present |

### 1.3 Runtime database evidence

Database counts from `.autoservice/database`:

```json
{
  "auth.db": {
    "login_tokens": 21,
    "operator_sessions": 4,
    "operators": 6,
    "sessions": 86
  },
  "cinnox/conversations.db": {
    "conversations": 145,
    "events": 1420,
    "messages": 780,
    "participants": 321
  },
  "_master/conversations.db": {
    "conversations": 7,
    "events": 61,
    "messages": 27,
    "participants": 14
  },
  "knowledge_base/kb.db": {
    "kb_chunks": 359
  },
  "dream_runs.db": {
    "dream_runs": 71
  },
  "proposals.db": {
    "proposals": 10
  }
}
```

Key runtime examples observed:

- Customer conversation `web_anon_f47a56c52dc8` in tenant `cinnox`:
  - customer asked: `帮我查一下我账号下昨天的工单状态`
  - filler reply: `好的，我马上查一下您账号下昨天的工单状态，稍等哈`
  - final agent reply asked for identity fields
- Operator/history evidence:
  - `participants` includes operator `IcUfIWt99liM7qba-9mggg`
  - events include `participant.joined`
  - events include mode transitions:
    - `auto -> copilot`
    - `copilot -> takeover` via `/hijack`
    - `takeover -> auto` via `/release`

### 1.4 Auth and API checks

The worksheet `.autoservice/access-credentials.md` contains online credentials, but the local `auth.db` hash state does not match those online passwords. Password login with the documented online passwords returned `invalid credentials` locally.

Because `AUTH_DEV_MODE=1` was enabled, dev-login was used for local E2E:

Admin dev-login:

```json
{
  "ok": true,
  "redirect": "/admin"
}
```

Admin session mode:

```json
{
  "mode": "master",
  "tenant_id": null,
  "authenticated": true,
  "authenticated_as": "admin@dev.local",
  "tier": 0,
  "role": "admin",
  "brand_name": "AutoService"
}
```

Operator dev-login:

```json
{
  "ok": true,
  "redirect": "/operator",
  "operator_id": "IcUfIWt99liM7qba-9mggg",
  "tenant_id": "cinnox",
  "email": "op@dev.local"
}
```

Operator `/api/auth/operator/me`:

```json
{
  "operator_id": "IcUfIWt99liM7qba-9mggg",
  "tenant_id": "cinnox",
  "email": "op@dev.local",
  "role": "responder",
  "force_password_change": false
}
```

Selected API results:

- `/api/conversations/active?tenant_id=cinnox`: returned real active conversation list.
- `/api/master/tenants`: returned `_master`, `cinnox`, `mystore`, many sandbox tenants.
- `/api/admin/kb/cinnox/sources`: returned KB sources including `CINNOX Pricing`, `CINNOX Feature List 2026`, `M800 Introduction`, `M800 Global Rates`.
- `/api/tenants/cinnox/versions`: returned `v1` through `v16`, current `v16`.
- `/api/cc_pool/runtime`: returned started pool with 4 available instances.
- `/api/sla/summary?tenant_id=cinnox`: endpoint works, metrics currently null/count 0 in this local runtime.
- `/api/dream/runs?tenant_id=cinnox`: returned historical completed Dream runs.
- `/api/upload`: returned `attachments disabled for this tenant`.
- `/chat/cinnox`: returned `unauthorized` without the required General Bot API credential.

## 2. Real AutoService E2E Scenarios

### A. Customer端

#### A1. Customer Chat SPA loads

Observed via Vite:

1. Start backend on 8000.
2. Start customer-chat on 5273.
3. Open `http://127.0.0.1:5273/`.
4. Page returns 200 with title `AutoService · Customer Chat`.

Status: Passed for SPA shell.

Notes:

- Direct backend path `/tenant/cinnox/chat` returned 404 in this local dev shape. The customer SPA is served by Vite, not by the backend process.
- Port 5173 was occupied by ezagent; use 5273 or free 5173.

#### A2. Customer message -> filler -> final agent reply

Observed from real `cinnox/conversations.db` data:

1. Conversation `web_anon_f47a56c52dc8` exists.
2. Customer message persisted as public message.
3. Agent sent a filler message with metadata `{"pipeline": "v2", "is_filler": true}`.
4. Agent sent final public reply with identity-collection guidance.
5. Conversation and events were persisted.

Status: Passed from real historical runtime data.

Dependencies:

- `PIPELINE_V2_ENABLED=true`
- cc_pool warmed
- tenant `cinnox` published/current runtime available

#### A3. Customer history/replay

Observed:

- `cinnox/conversations.db` contains 145 conversations, 780 messages, 1420 events.
- `/api/conversations/active?tenant_id=cinnox` returned the recent active conversation list when called with operator session.

Status: Passed for persisted history and active list visibility.

#### A4. Attachment upload

Observed:

- `POST /api/upload` returned:

```json
{
  "detail": "attachments disabled for this tenant"
}
```

Status: Blocked by tenant/runtime config.

Required to pass:

- Enable `ATTACHMENT_ENABLED=1`.
- Include `cinnox` in `ATTACHMENT_ENABLED_TENANTS`.
- Provide upload storage path under sandbox.

#### A5. General Bot API

Observed:

- `POST /chat/cinnox` without credential returned:

```json
{
  "error": "unauthorized"
}
```

Status: Endpoint exists, blocked by missing API credential in this run.

Required to pass:

- Valid Bearer/API key expected by the AutoService General Bot API.

#### A6. Voice call

Observed at backend startup:

- Voice backend resolved to Doubao:
  - TTS: `https://openspeech.bytedance.com/api/v3/tts/unidirectional`
  - ASR: `wss://openspeech.bytedance.com/api/v3/sauc/bigmodel`

Status: Not run end-to-end.

Required to pass:

- Doubao credentials.
- Browser media permissions/fake media.
- Voice gateway path.
- External service quota/cost control.

### B. Operator端

#### B1. Operator SPA loads

Observed:

1. Start operator-console on 5274.
2. Open `http://127.0.0.1:5274/`.
3. Page returns 200 with title `AutoService · Operator Console`.

Status: Passed for SPA shell.

#### B2. Operator login

Observed:

1. Password login with online worksheet passwords failed locally due local DB mismatch.
2. `POST /api/auth/operator/dev-login` succeeded under `AUTH_DEV_MODE=1`.
3. `/api/auth/operator/me` returned the active responder identity.

Status: Passed via local dev-login; password login blocked by local credential mismatch.

Local test identity:

- tenant: `cinnox`
- email: `op@dev.local`
- operator id: `IcUfIWt99liM7qba-9mggg`
- role: `responder`

#### B3. Operator active conversation list

Observed:

- `/api/conversations/active?tenant_id=cinnox` returned real active conversations, including customer id, mode, state, last message, last sender, activity timestamp, squad id.

Status: Passed.

#### B4. Operator join/copilot/takeover/release

Observed from real DB events:

- `participant.joined` event for operator.
- `mode.changed` event:
  - `auto -> copilot` on operator join
  - `copilot -> takeover` with trigger `/hijack`
  - `takeover -> auto` with trigger `/release`

Status: Passed from real historical runtime data.

#### B5. Operator pool busy/SLA visibility

Observed:

- `/api/cc_pool/runtime` returned:

```json
{
  "started": true,
  "max_size": 5,
  "checked_out": 0,
  "sticky": 0,
  "available": 4,
  "total": 4
}
```

- `/api/sla/summary?tenant_id=cinnox` returned the expected shape with null metrics/count 0.

Status: Endpoint passed; meaningful SLA data absent in this local runtime.

### C. Admin端

#### C1. Admin SPA loads

Observed:

1. Start admin-portal on 5275.
2. Open `http://127.0.0.1:5275/`.
3. Page returns 200 with title `AutoService · Admin Portal`.

Status: Passed for SPA shell.

#### C2. Admin login/session mode

Observed:

1. Password login with online worksheet password failed locally.
2. `POST /api/auth/dev-login` succeeded under `AUTH_DEV_MODE=1`.
3. `/api/session/mode` returned authenticated tier-0 admin.

Status: Passed via local dev-login; password login blocked by local credential mismatch.

#### C3. Master tenant list

Observed:

- `/api/master/tenants` returned tenant list containing `_master`, `cinnox`, `mystore`, and many sandbox tenants.

Status: Passed.

#### C4. KB source management

Observed:

- `/api/admin/kb/cinnox/sources` returned real KB source list.
- Examples:
  - `CINNOX Pricing`
  - `CINNOX Feature List 2026`
  - `M800 Introduction`
  - `M800 Global Rates`
  - `CINNOX Glossary`

Status: Passed for listing.

#### C5. Version/publish history

Observed:

- `/api/tenants/cinnox/versions` returned versions `v1` through `v16`.
- Current version is `v16`.

Status: Passed for version listing.

#### C6. Dream runs

Observed:

- `/api/dream/runs?tenant_id=cinnox` returned completed historical Dream runs.
- `dream_runs.db` contains 71 rows.

Status: Passed for historical run listing.

#### C7. Inbox/CR proposals

Observed:

- `/api/admin/inbox/cinnox` returned empty grouped inbox with `total: 0`.
- `proposals.db` contains 10 proposals.

Status: Endpoint passed; no pending cinnox inbox items at run time.

#### C8. Soul/Skill section reads

Observed:

- `/api/admin/section/cinnox/customer/greeting` returned no slots for that section.
- `/api/admin/skills/cinnox/customer` returned 404.

Status: Route reachable but selected section/skill names did not match current tenant layout.

Required to pass:

- Use actual section ids and skill ids from the tenant's current released/sandbox layout.

## 3. Ezagent Reproduction Mapping

### 3.1 Directly reproducible in ezagent

| AutoService scenario | Ezagent equivalent | Evidence in ezagent |
|---|---|---|
| Customer/API message roundtrip | Session message -> routing -> agent reply | `docs/e2e/scenario-04-echo-roundtrip.md`, `scenario-05-cc-roundtrip.md`, `scenario-06-codex-roundtrip.md`, `scenario-07-curl-roundtrip.md` |
| Customer history/replay | Session message store and session view | `docs/e2e/scenario-03-create-session.md`, session E2E tests under `apps/ezagent_domain_session/test/e2e` |
| Operator login | Identity/password/magic-link flows | `docs/scenarios/01-magic-link-login`, `docs/scenarios/02-password-login-admin`, `docs/e2e/scenario-01-operator-login.md` |
| Operator opens session | Session membership and route visibility | `docs/scenarios/09-session-create-lv`, `docs/scenarios/16-workspace-switch-visibility` |
| Mention-gated dispatch | Routing rules and mention filtering | `docs/e2e/scenario-08-mention-routing.md`, `docs/scenarios/10-mention-gated-routing` |
| Cross-session rejection | Sender/member locked routing | `docs/e2e/scenario-09-cross-session-reject.md`, `docs/scenarios/11-cross-session-mention-rejected`, `docs/scenarios/34-sender-locked-relay` |
| Feishu inbound/outbound | Feishu plugin binding/inbound dispatch | `docs/e2e/scenario-10-feishu-bind.md`, `docs/e2e/scenario-11-feishu-inbound.md`, `apps/ezagent_plugin_feishu/test/e2e/category_04_feishu_test.exs` |
| General Bot/OpenAI-compatible API | Protocol API plugin | `apps/ezagent_plugin_protocol_api/test/ezagent/protocol_api/openai_chat_plug_integration_test.exs` |
| Admin/workspace list | Workspace lifecycle | `docs/scenarios/20-workspace-lifecycle`, World UI scenarios |
| Agent configuration | Agent console / template / flavor config | `docs/scenarios/29-admin-lv-smoke`, `docs/scenarios/30-plugin-author-behavior` |

### 3.2 Partially reproducible in ezagent

| AutoService scenario | Ezagent status | Missing/adaptation |
|---|---|---|
| Customer public widget | Partial | Ezagent has external/anonymous access scenarios, but not AutoService's exact React widget/sessionStorage `customerId` model. |
| Operator copilot/takeover | Partial | Ezagent has members, caps, routing, visibility concepts. It does not have AutoService's exact operator console takeover timer and slash-command UX. |
| Pool busy warning | Partial | Ezagent can expose agent/runtime health depending on flavor, but not AutoService cc_pool utilization API shape. |
| Soul/Skill editing | Partial | Ezagent uses SessionTemplate/Behavior/Agent flavor config, not AutoService L0-L3 Soul + slots + skill markdown model. |
| Publish history/rollback | Partial | Ezagent can use config/git/workspace state, but lacks AutoService's tenant release pointer pipeline and version archive semantics. |
| CSAT | Partial | Could be represented as session action/message metadata, but no built-in CSAT product surface was verified. |

### 3.3 Not reproduced in ezagent without new development

| AutoService scenario | Reason |
|---|---|
| KB ingestion/vector search/source management | Ezagent has no matching KB ingestion/source manager subsystem. |
| Dream engine -> proposal -> CR -> publish | Ezagent has no AutoService-style Dream/CR governance loop. |
| Sandbox preview -> publish archive -> pointer flip | Ezagent config model is different; no tenant sandbox release pipeline. |
| Billing dashboard | Not an ezagent core capability. |
| SLA analytics dashboard | No equivalent analytics module verified. |
| Voice call ASR/TTS | Requires voice channel, Doubao ASR/TTS, browser media path. |
| Attachment upload storage policy | Ezagent message metadata can carry attachments, but no equivalent AutoService upload endpoint/storage flow was verified. |

## 4. Ezagent Verification Attempt

Commands attempted:

```bash
mix test apps/ezagent_plugin_protocol_api/test \
  apps/ezagent_plugin_feishu/test \
  apps/ezagent_core/test/e2e \
  apps/ezagent_domain_session/test/e2e --color
```

and narrower variants.

Result:

- The umbrella test run did not complete in this environment.
- Blocking error:

```text
Could not start application ezagent_plugin_echo: could not find application file: ezagent_plugin_echo.app
```

- `--no-start` variants also cannot be used for these tests because `test_helper.exs` configures Ecto SQL Sandbox and requires `EzagentCore.Repo` to be started.

Interpretation:

- This is an ezagent local test-environment issue, not evidence that the mapped capabilities are absent.
- The repo contains existing E2E docs and test files for protocol API, Feishu, session routing, agent roundtrips, identity, and admin smoke scenarios. Those are the intended ezagent reproduction surfaces.

## 5. Reproduction Dependencies and Setup

### 5.1 AutoService

Required:

- Python 3.11+ / current `.venv`
- `uvicorn`
- `.env` and `.autoservice/config.local.yaml`
- `AUTH_DEV_MODE=1` for local dev-login unless local password hashes match known credentials
- `NO_PROXY`/`--noproxy '*'` when local environment has HTTP proxy variables
- `pnpm install` under `frontend` when running from WSL against a Windows-origin `node_modules`
- cc_pool external model credentials if running live agent turns
- DeepSeek/Anthropic credentials for full Pipeline V2 and cc_pool behavior
- Doubao credentials for voice E2E
- General Bot API credential for `/chat/{tenant_id}`
- Attachment config flags for `/api/upload`

Local startup:

```bash
# backend
AUTH_DEV_MODE=1 PLACEHOLDER_ENABLED=0 \
  .venv/bin/uvicorn autoservice.web_gateway:create_app \
  --factory --host 127.0.0.1 --port 8000 --log-level info

# frontends, alternate ports used in this run
cd frontend
pnpm --filter @autoservice/customer-chat exec vite --host 127.0.0.1 --port 5273
pnpm --filter @autoservice/operator-console exec vite --host 127.0.0.1 --port 5274
pnpm --filter @autoservice/admin-portal exec vite --host 127.0.0.1 --port 5275
```

### 5.2 Ezagent

Required:

- Resolve local test startup issue around missing `ezagent_plugin_echo.app`, or update tests that still assume the retired echo plugin.
- Use existing scenario set:
  - `docs/e2e/scenario-01-operator-login.md`
  - `docs/e2e/scenario-03-create-session.md`
  - `docs/e2e/scenario-04-echo-roundtrip.md`
  - `docs/e2e/scenario-06-codex-roundtrip.md`
  - `docs/e2e/scenario-07-curl-roundtrip.md`
  - `docs/e2e/scenario-10-feishu-bind.md`
  - `docs/e2e/scenario-11-feishu-inbound.md`
  - `docs/e2e/scenario-12-dispatch-audit.md`
- Configure Feishu credentials for live Feishu E2E.
- Configure protocol API/default agent for OpenAI-compatible API E2E.
- Configure real cc/codex/curl/py agent credentials depending on the chosen agent flavor.

## 6. Final Coverage Assessment

| Area | AutoService real E2E status | Ezagent reproduction status |
|---|---|---|
| Customer SPA shell | Passed | Public/external view partially analogous |
| Customer message/agent reply | Passed from real DB; live new turn not forced | Reproducible via session/agent roundtrip scenarios |
| Customer history | Passed | Reproducible |
| Attachment upload | Blocked by AutoService tenant config | Missing/partial |
| Voice | Not run; external Doubao dependency | Missing |
| Operator SPA shell | Passed | World/session UI analogous |
| Operator login | Passed via dev-login; local password mismatch | Reproducible via identity scenarios |
| Operator active list | Passed | Session list/membership analogous |
| Operator copilot/takeover | Passed from DB events | Partial; needs product-specific UX |
| Admin SPA shell | Passed | World/Admin smoke analogous |
| Admin tenant list | Passed | Reproducible via workspace lifecycle |
| Admin KB | Passed in AutoService | Missing in ezagent |
| Admin publish versions | Passed in AutoService | Partial/different model |
| Dream/CR | Historical run listing passed | Missing |
| General Bot API | Endpoint present, unauthorized without key | Reproducible through protocol API with configured key |
| Feishu | Not live-run here | Reproducible with plugin + credentials |

## 7. Main Findings

1. AutoService has real runtime evidence for the core customer/operator/admin flow, not just code paths. The local DB contains customer turns, filler/final PV2 replies, operator joins, takeover, release, KB sources, Dream runs, and publish history.
2. Local AutoService password credentials differ from the online worksheet. For this run, `AUTH_DEV_MODE=1` was required to execute admin/operator login flows.
3. Full customer live turn and General Bot API require credentials/config not available in this run: model/API credentials, General Bot API auth, and optional attachment flags.
4. Ezagent can reproduce the core agent/session/routing/API/Feishu concepts, but not AutoService's KB, Dream/CR, release-publish, billing/SLA analytics, or voice subsystems without new development.
5. Ezagent's current umbrella test startup is blocked by stale `ezagent_plugin_echo` application expectations. Existing docs and test files identify the intended reproduction surfaces, but a clean automated run needs that startup issue fixed first.
