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
| CLI probe — Kimi platform profile (`kimi-k3`, moonshot.ai) | **Vendor 401** — the placed key is a Kimi for Coding SUBSCRIPTION key, not an open-platform key (root-caused 2026-07-18; see `05-kimi-coding-lane.md`) |
| CLI probe — kimi-coding (`kimi-k3[1m]`, api.kimi.com/coding) | **PASS** (exit 0, `ok`, 6.3 s) |
| Boot: seeded cc-orchestrator = cc-custom + deepseek | **PASS** (template content read live) |
| cc-custom PTY + deepseek: create via product dispatch | **PASS** (fork → write → instantiate) |
| cc-custom PTY: spawn, model identity, bridge topic | **PASS** (`deepseek-v4-pro[1m]` in TUI; `agent_bridge:cc-custom:` joined) |
| cc-custom PTY: cold restart re-resolves flavor+profile | **PASS** (flavor/provider re-read from `respawn_template_data`; no secret persisted) |
| cc-custom PTY + deepseek: chat round-trip (world UI) | **PASS** (`ds-pong`, ~11 s) |
| cc-custom PTY + kimi-coding: create / spawn / model identity | **PASS** (`kimi-k3[1m] · API Usage Billing` in TUI; `agent_bridge:cc-custom:` joined) |
| cc-custom PTY + kimi-coding: chat round-trip (world UI) | **PASS** (`kc-pong`, ~4 s) |
| cc-custom PTY + kimi-coding: cold-restart spot check | **PASS** (flavor+profile re-resolve; PTY respawns; zero persisted secret) |
| cc-headless-custom live spawn (any profile) | **NOT PROVEN** — ad-hoc lanes each independently blocked (F2/F3/F4; pre-existing/generic) |
| Negative: `provider: "bogus"` at create | **PASS** — `{:invalid_template_data, {:unknown_backend_profile, "bogus"}}`, no spawn |
| Negative: keyless create (deepseek) | **PASS** — `{:backend_api_key_missing, "deepseek", <uri>}` before any spawn |
| Negative: keyless orchestrator socialware slot | **PASS** — SKIPS with `{:credential_unavailable, "cc-custom"}`; install completes (chain-C) |
| Negative sanity: platform-kimi 401 is vendor-reject, not our gates | **PASS** — with `MOONSHOT_API_KEY` present the launch env builds; the 401 comes from the vendor (`05-kimi-coding-lane.md` §1) |

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
- `05-kimi-coding-lane.md` — the 2026-07-18 kimi-coding completion: unblock
  context, both kimi-surface CLI probes (subscription PASS / platform 401
  negative sanity), the cc-custom PTY product proof on `kimi-coding`, the
  cold-restart spot check.
- `server-run2-excerpts.txt` — sanitized server-log excerpts of the deepseek
  product run (spawn, bridge join, TUI banner, chat round-trip).
- `server-run3-keyless-excerpts.txt` — the keyless-run SKIP lines verbatim.
- `server-run4-5-kimi-coding-excerpts.txt` — sanitized excerpts of the
  kimi-coding run (spawn, banner, chat) + the cold-restart respawn.
- `shots/` — `chat-roundtrip-both-vendors.png` (one session, `ds-pong` +
  `kc-pong`), `chat-roundtrip-deepseek.png`,
  `keyless-orchestrator-skip.png` (1-member session after the skip),
  `keyless-install-form.png`.

## Operator follow-ups (out-of-band)

1. ~~Replace `MOONSHOT_API_KEY`~~ — RESOLVED 2026-07-18: the key is a Kimi
   for Coding subscription key; the catalog now carries the matching
   `kimi-coding` profile (commit `11770568c`) and this directory proves the
   lane end-to-end. An open-platform key would be needed only to use the
   `kimi` (platform) profile.
2. **Rotate `DEEPSEEK_API_KEY` and `KIMI_CODING_API_KEY`** — F1: both landed
   in local PtyServer crash logs on this host (destroyed here, but treat as
   exposed).

## Cleanliness proof (run before commit)

```
$ grep -rInE 'sk-[A-Za-z0-9]|esr_pat_v1_[A-Za-z0-9]|tok_[A-Za-z0-9]' docs/e2e/2026-07-17/cc-custom-live-proof/
(no matches)
```
