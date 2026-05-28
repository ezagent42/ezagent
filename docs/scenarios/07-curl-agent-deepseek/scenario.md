# Scenario 07: curl agent — spawn → DeepSeek round-trip

**Category**: 2 — Agent lifecycle
**Status**: ✅ implemented-and-tested
**Last verified**: 2026-05-19 (PR #126 evidence)

## Pre-conditions

- Phx running at `http://100.64.0.27:10042`
- DeepSeek API key on hand (`sk-deepseek-...`)
- Admin logged in
- A non-admin user (preferred per `feedback_e2e_prefers_non_admin_user`) who will hold the api-key

## Actors

- **Caller**: admin or non-admin user
- **Target**: curl agent `curl-agent://my-deepseek` (Kind: `Ezagent.Entity.CurlAgent`)
- **External systems**: `https://api.deepseek.com/chat/completions` (or OpenAI-compatible)

## Steps

1. Login as non-admin user U.
2. Open `/admin/users/<U>/api-keys`; click "Add api key"; provider `deepseek`, key `sk-deepseek-...`.
3. Verify the key is stored masked (e.g. `sk-06a5...0a7c`) in the LV.
4. Open `/admin/templates`; click "Create curl.agent template"; fill:
   - `class = curl.agent`
   - `agent_uri = curl-agent://my-deepseek`
   - `provider = deepseek`
   - `api_url = https://api.deepseek.com/chat/completions`
   - `owner_uri = entity://user/system/<U>` (where the api-key lives)
5. Open `/admin/routing`; add rule `{:always} → ["curl-agent://my-deepseek"]` for the session.
6. In `/admin/sessions/<session-uri>`, send: "DeepSeek say hello in one sentence please".
7. Verify the curl agent posts to DeepSeek + appends the reply to the session.

## Expected outcomes

- Slice `:api_keys` on the User Kind contains the key (per PR #389 the api-key Behavior is on Agent Kind, but the scenario chain still flows from User → Agent).
- An invocation chain: user `chat.send` → routing → `curl-agent://my-deepseek` `chat.receive` → http POST → reply → `chat.send` from agent.
- Session shows admin's message + agent's reply.
- No api-key in any log, audit row, or session message (`apps/ezagent_plugin_curl_agent/lib/ezagent/...` masks it).

## Failure modes to test

- Invalid api-key: DeepSeek returns 401; curl agent emits `chat.send` with "Error: 401 unauthorized" — admin sees the error in session (do NOT leak the key).
- DeepSeek down (network unreachable): `:httpc` retries N times, then surfaces a timeout error to the session.
- User without api-key: `:get_api_key` dispatch fails; curl agent surfaces "missing api-key for provider deepseek" to the session.

## Cross-references

- Related PRs:
  - PR #126 — curl-agent plugin (initial)
  - PR #389 — api-keys flipped to Agent Kind
- Related SPECs: none (PR #126 predates the SPEC discipline)
- Tests:
  - `apps/ezagent_plugin_curl_agent/test/integration/plugin_contract_test.exs`
  - `apps/ezagent_domain_identity/test/ezagent/app_settings_test.exs` (api-keys slice)
- Evidence + runbook:
  - `docs/notes/curl-agent-walkthrough.md`
  - `docs/notes/evidence/pr126-curl-agent-deepseek-e2e.webm`
  - `docs/notes/evidence/pr126-04-deepseek-reply.png`

## Notes

- The curl agent uses `:httpc` (Erlang stdlib) for HTTP, matching the Feishu plugin's stdlib-only choice — no new deps.
- URI scheme is `curl-agent://` (distinct from `agent://`), giving its own `(Kind, action)` registry entry per Decision Log.
- This is the cleanest example of a per-user-key, per-agent-instance scenario today.
