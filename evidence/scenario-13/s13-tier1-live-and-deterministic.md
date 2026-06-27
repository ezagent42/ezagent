# scenario-13 Tier-1 — evidence (2026-06-27)

Seed: `scripts/autoservice_tier1_seed.exs` (`Ezagent.AutoService.Tier1Seed`).
Deterministic regression: `apps/ezagent_plugin_kb/test/e2e/autoservice_tier1_seed_test.exs`.
Live serve-seed: `scripts/autoservice_tier1_serve_seed.exs`.

Disposable dev stack: `EZAGENT_HOME=/tmp/ezagent_autosvc_e2e`, PG `ezagent_pg_compat_autosvc_e2e`
(docker :55432), `MIX_ENV=dev`. Unit tests: `MIX_TEST_PARTITION=autosvc`.

---

## Deterministic regression (CI-judgeable) — 20/20 kb tests green

`mix test apps/ezagent_plugin_kb/test/e2e/autoservice_tier1_seed_test.exs --include integration`
→ `2 tests, 0 failures` (full kb suite `20 tests, 0 failures`).

Proves, exercising the SHIPPED seed module (`Code.require_file`):
- **S2a/S2b (routing)**: a BARE customer message (no @mention) resolves to the
  AutoService agent via the seeded `in_session→agent` rule; a bare message in a
  DIFFERENT session does NOT (rule is session-scoped, not global).
- **S3 retrieval soul**: the AutoService agent HOLDS `kb.query` in its identity
  slice (read back via `Identity.list_caps_for` — the live orchestrator's cap
  source), and `kb.query` with those READ-BACK caps returns the corpus-only
  fact `ZEPHYR-7731`. Negative control: a capless principal is denied.
- **S3 audit signal**: `[:ezagent,:authz,:granted]` telemetry fires for the
  kb.query dispatch (the Audit.Writer source).
- **Idempotency**: re-seed reuses URIs + does not duplicate the route.

---

## Live (disposable dev node, Audit.Writer enabled)

### Seed wires the chain end-to-end (cc agent reported blocked, non-fatal)
```
[info] autosvc-seed: ingested 1 chunk(s) into entity://autosvc/agent/kb-tier1
[info] autosvc-seed: routing rule always(in_session)→entity://autosvc/agent/autoservice id=2
seed OK
  kb-agent         : entity://autosvc/agent/kb-tier1
  AutoService agent: entity://autosvc/agent/autoservice  (status: {:blocked, {:role_unsupported_for_flavor, "cc"}})
  session          : session://autosvc/default/tier1
  rule_id          : 2
```
→ kb-agent (flavor `native` × role `kb`) created live, corpus ingested,
public_view session created, `always(in_session)→agent` route installed.

### S1 — public_view gate (server-side), phx.server on :10056, session live in-node
```
GET /socialware/chat?session_uri=session://autosvc/default/tier1   → HTTP 200   (anon allowed)
GET /socialware/chat?session_uri=session://autosvc/default/<none>  → HTTP 302   (control: gate redirects)
GET /assets/js/customer_app.js                                     → HTTP 404
```
→ the public_view gate ADMITS the anonymous customer into the seeded session
(200), and DISCRIMINATES (a non-public session → 302). The customer SPA bundle
is 404: the React frontend moved to Vite (`main.tsx`); the 2026-06-21
socialware recipe's `customer_app.js` is stale, and `node_modules` is not
installed (recipe §0 `pnpm install` + `mix assets.build` prerequisite). The
page is HTTP-200 but renders blank without the bundle — a frontend-build
prerequisite, NOT a seed gap. Full SPA screenshot deferred to the web/vite
stack.

### S3 — live kb.query + persisted audit row (scenario-12 step-5)
Dispatched `kb.query` against the live kb-agent (writer enabled):
```
kb.query OK — hit contains ZEPHYR-7731? true
persisted `query`/`granted` invocations for kb-agent:
  %{caller: "entity://system/user/admin",
    target: "entity://autosvc/agent/kb-tier1?action=kb.query",
    action: "query", authz: "granted"}   (x2)
AUDIT-ROW: FOUND (2)
```
→ retrieval returns the corpus-only fact AND a persisted `query`/`granted`
invocation row exists — the audit corroboration the :test unit could not do
(`Audit.Writer` disabled in :test). cc-INDEPENDENT.

---

## Remaining GAPs (precise, observed — not blocking the above)

1. **cc-orchestrator AutoService agent is NOT a `create_agent` role.**
   `Workspace.create_agent(flavor: "cc", role: "orchestrator")` returns
   `{:error, {:role_unsupported_for_flavor, "cc"}}`. A cc-flavor orchestrator
   is materialized via the **session-create orchestrator-template path**
   (`EzagentDomainInstanceMessage.SessionCreator` + the cc-orchestrator
   `AgentTemplate`, `cc_orchestrator_seed.ex` + `orchestrator_bootstrap.ex`),
   which delegates caps session-side. The seed therefore reports the cc agent
   `{:blocked, …}` and wires the rest of the chain (S1/S2a/S3-retrieval/S4)
   regardless. **Follow-up:** add a seed variant that materializes the
   AutoService agent through SessionCreator's orchestrator path.

2. **S3/S2b ANSWER layer (live cc tool-loop).** Even with #1 solved, the
   answer-level soul — a live `claude` cc-orchestrator weaving `ZEPHYR-7731`
   into a CHAT REPLY via the orchestrator MCP `kb_query` tool — rides cc's
   PTY/startup path (#505 fixed the reply mute via
   `--dangerously-skip-permissions`; expired OAuth→401 also mutes). Verify on a
   disposable stack with valid claude auth once #1 lands.

3. **S4 operator console (browser).** The session is created + visible in the
   DB/console; the world-LV visual (members online + transcript) needs the
   web/vite stack + admin login. Deferred with S1's full SPA render.
