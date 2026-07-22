# Return: Git Provider V1 — Plan D2 GitHub Plugin

> **Date:** 2026-07-21 · **From:** Claude session (D2 implementation) · **To:** Allen
> **Tracking:** Git Provider V1 / Draft PR #1445
> **Branch:** `feat/git-domain-spine`
> **Status:** D2 complete — 9 modules, 59 tests/0 failures, 11 commits

## 1. Scope delivered

`apps/ezagent_plugin_github` — standalone OTP app implementing GitHub OAuth App
authorization and Git REST API operations, callable by agents.

**9 modules:**

| Module | Behaviour | Purpose |
|---|---|---|
| `application.ex` | `Ezagent.Plugin` | Boot + register Driver/BackendPair/Adapter |
| `github_driver.ex` | `Driver` (8 callbacks) | OAuth begin/consume/refresh/reconcile/discard/revoke |
| `github_adapter.ex` | `DomainGit.Adapter` (5 callbacks) | Git API via Req (resolve/create/read/list checks+reviews) |
| `github_credential_backend.ex` | `CredentialBackend` (8 callbacks) | Token encrypt/store/replace/revoke |
| `github_token_store.ex` | — | AES-256-GCM encrypt/decrypt |
| `github_client.ex` | — | Req wrapper (get/post/patch + 5 error mappings) |
| `github_oauth.ex` | — | OAuth URL construction + code→token exchange |
| `github_callback_plug.ex` | Plug | GET /github/callback → CallbackIngress |
| `config.ex` | — | Runtime config (OAuth keys + redirect URI) |

**Key decisions:**
- OAuth App (authorization code flow), NOT GitHub App — token never expires, refresh is no-op
- Token stored in Process dict for TDD phase; production upgrade path to ETS → Ecto documented
- Callback via Plug forwarded from web router (feishu pattern)
- `provider_adapter: :github` (atom, not module name)
- Redirect URI from config, not hard-coded
- credential_material as `{:write_only_handoff, token}` — opaque to D1, secured by D1's EffectBoundary

## 2. Verification

- GitHub plugin suite: **59 tests / 0 failures**
- Provider-connection suite: 331 tests, facade gate fixed (reconcile_refresh added as legitimate facade entry point), remaining failures are D1's known concurrency flake class
- arch.scan: 7/7 + 42/42 green
- doc.scan: 405/404 (pre-existing ezagent_web debt, not introduced by D2)
- umbrella compile `--warnings-as-errors`: clean

## 3. Codex review

Two rounds:
- Batch 1 review: 5 findings (1 BLOCKER token-as-identity + 4 MAJOR) → all fixed
- Final review: 9 findings (4 BLOCKER + 5 MAJOR) → all fixed

## 4. Known TDD placeholders

1. CredentialBackend uses Process dictionary — production needs ETS or Ecto
2. Adapter `token/0` returns empty string — needs CredentialBackend.lease_for_operation wiring
3. OAuth App tokens don't expire — refresh is no-op. GitHub App upgrade will implement real refresh
4. No server-side revoke (DELETE /applications/{client_id}/token) — D2 only clears local storage

## 5. Non-goals (explicitly excluded)

- GitHub App (installation model)
- Pagination, rate limiting, webhooks
- Kanban integration, socialware manifest, agent skill — Allen's layer
