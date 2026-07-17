# cc-custom live proof — 2026-07-17 (T7 / PR-7, lead-authorized local run)

**Scope:** the final build gate of the cc-custom-backends build (design
`docs/superpowers/specs/2026-07-17-cc-custom-backends-design.md` §2.4 + §11):
CLI probes against both vendors, the product-path proof for the two custom
flavors, and the negative proofs — all on a locally booted dev node from the
`feat/cc-custom-backends` worktree @ `d9e429b9e`.

**Secret hygiene:** keys were sourced only via
`set -a; . ~/.ezagent/default/credentials/cc-custom.env; set +a`. No key value
was ever printed, logged into this directory, or committed. Before commit this
whole directory was grep-proven clean of `sk-` / token patterns (command +
result recorded at the bottom of this file). One leak was found in the
PRODUCT's own crash logging — see `04-findings.md` F1 (raw local logs
sanitized/destroyed; the operator should rotate the DeepSeek key).

## Verdicts at a glance

| Proof | Result |
|---|---|
| CLI probe — DeepSeek (`deepseek-v4-pro[1m]` per catalog) | **PASS** (exit 0, `ok`, 7.5 s) |
| CLI probe — Kimi (`kimi-k3`) | **BLOCKED at vendor** — 401 Invalid Authentication, all endpoints/schemes (operator key issue) |
| Boot: seeded cc-orchestrator = cc-custom + deepseek | **PASS** (template content read live) |
| cc-custom PTY + deepseek: create via product dispatch | **PASS** (fork → write → instantiate) |
| cc-custom PTY: spawn, model identity, bridge topic | **PASS** (`deepseek-v4-pro[1m]` in TUI; `agent_bridge:cc-custom:` joined) |
| cc-custom PTY: cold restart re-resolves flavor+profile | **PASS** (flavor/provider re-read from `respawn_template_data`; no secret persisted) |
| cc-custom PTY: chat round-trip through world UI | **PASS** (`ds-pong`, ~11 s) |
| cc-headless-custom + kimi: live spawn + chat | **NOT PROVEN** — vendor 401 (primary); three ad-hoc create lanes each independently blocked (secondary, see `04-findings.md` F2/F3/F4) |
| Negative: `provider: "bogus"` at create | **PASS** — `{:invalid_template_data, {:unknown_backend_profile, "bogus"}}`, no spawn |
| Negative: keyless create (deepseek) | **PASS** — `{:backend_api_key_missing, "deepseek", <uri>}` before any spawn |
| Negative: keyless orchestrator socialware slot | **PASS** — SKIPS with `{:credential_unavailable, "cc-custom"}`; install completes (chain-C) |

## Files

- `01-cli-probes.md` — the §2.4 commands verbatim (env NAMES only), exit
  status, response shape, model identity, durations, and the Moonshot 401
  forensics (endpoints × auth schemes × key charset, values never shown).
- `02-product-path-proof.md` — environment, boot proof, agent-1 create /
  spawn / cold-restart / chat round-trip, agent-2 blocker analysis.
- `03-negative-proofs.md` — the three negative proofs with exact error tuples.
- `04-findings.md` — F1 secret-in-crash-log (CRITICAL, pre-existing class),
  F2/F4 pre-existing template-path bugs, F3 flavor-config gap, F5 CLI chat
  gap, F6 environment notes.
- `server-run2-excerpts.txt` — sanitized server-log excerpts of the product
  run (spawn, bridge join, TUI banner, chat round-trip).
- `server-run3-keyless-excerpts.txt` — the keyless-run SKIP lines verbatim.
- `shots/` — `chat-roundtrip-deepseek.png` (the `ds-pong` reply bubble),
  `keyless-orchestrator-skip.png` (1-member session after the skip),
  `keyless-install-form.png`.

## Operator follow-ups (out-of-band)

1. **Replace `MOONSHOT_API_KEY`** — the placed key is rejected by the vendor
   (see `01-cli-probes.md`); re-running this proof with a valid key exercises
   the kimi lane (its spawn-lane gaps are tracked in `04-findings.md`).
2. **Rotate `DEEPSEEK_API_KEY`** — F1: it landed in local PtyServer crash logs
   on this host (destroyed here, but treat as exposed).
3. Normalize the credentials file to LF and `chmod 600`.

## Cleanliness proof (run before commit)

```
$ grep -rInE 'sk-[A-Za-z0-9]|esr_pat_v1_[A-Za-z0-9]|tok_[A-Za-z0-9]' docs/e2e/2026-07-17/cc-custom-live-proof/
(no matches)
```
