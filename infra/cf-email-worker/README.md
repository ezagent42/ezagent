# ezagent inbound email worker (task #88)

A Cloudflare Email Worker that receives inbound mail for **ezagent.chat**, parses
it (postal-mime), and caches it in **KV** for 30 days. A token-authed pull API
(the same Worker's `fetch` handler) lets ezagent / an operator list and fetch
received messages. This is the "CF Email Worker → cache" half of inbound email;
ezagent's external-adapter can later poll the pull API to ingest mail as session
messages (#88 second half).

## Resources (deployed 2026-06-22, account ec413d68…)

- Worker: `ezagent-email-inbox` → https://ezagent-email-inbox.allenwoods.workers.dev
- KV namespace binding `EMAIL_INBOX` (id in `wrangler.jsonc`)
- Secret `PULL_TOKEN` (set via `wrangler secret put PULL_TOKEN`; NOT in repo)

## Pull API (Authorization: Bearer $PULL_TOKEN)

- `GET /inbox` — list all cached emails (newest first, ≤100)
- `GET /inbox?to=<addr>` — list for one recipient
- `GET /inbox/<key>` — one message by key (`inbox:<to>:<ts>:<msgid>`)

Each record: `{key, from, to, subject, date, text, html, messageId, receivedAt, size}`.

## Deploy / update

```bash
cd infra/cf-email-worker
pnpm install
export CLOUDFLARE_API_TOKEN=<token>            # Workers + Workers KV: Edit
export CLOUDFLARE_ACCOUNT_ID=ec413d68e6a97533c1dc819c90a106e3
wrangler deploy
printf '%s' "<pull-token>" | wrangler secret put PULL_TOKEN
```

## Manual step (CF dashboard — token lacks Email Routing rules perm)

Email Routing rules (catch-all → Worker) need a permission beyond "Email Routing
Addresses: Edit", so do this once in the dashboard:

1. ezagent.chat → Email → Email Routing → **Enable** (adds MX; coexists with
   Email Sending).
2. Routing rules → **Catch-all** → action **Send to a Worker** →
   `ezagent-email-inbox`.

After that, mail to any `*@ezagent.chat` is parsed + cached + pullable.
