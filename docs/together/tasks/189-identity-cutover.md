# #189 身份平面 cutover — 读翻转 + ephemeral 持久身份 → 9 红转绿

- **id**: `189-identity-cutover`
- **owner**: Allen 轨道(cc 协调)
- **status**: wip
- **历史**: started 2026-07-28 · est_done 2026-07-29 · actual —
- **关联**: PR #1615(PR-1, merged bc1b9fb74) · branch fix/189-identity-plane-p2 @ 写平面 87e21fc35 · codex: PR-1 六轮 MERGE-OK+SOUND; PR-2 写平面 impl FIX-NEEDED→已修; 整包一次 codex 待 cutover 完

- **branch**: `fix/189-identity-plane-p2`（基于 main `bc1b9fb74` = PR-1 已入 + 写平面 `87e21fc35`）
- **依赖**: 写平面已完成并验证（原子 active-transition 闸 / backfill / fleet-parity barrier / open(:existed) fail-closed，Allen 已确认 A：门保持）

## 目标

冷启动自派发 `:holder_revoked` 根因收口：读平面翻到 store-authoritative + ephemeral 持有者
（ExternalMirrorWorker / Session）获得持久 self-license → main full-suite 的 9 个
holder_revoked 红转绿 → 整包一次 codex 过审 → 一次合入 → main 真绿 → 自动放行 canary。

## 验收

- [ ] 9 个 holder_revoked 红全部转绿（external_mirror 8：WorkerPublish×3、Resubscribe/Catchup×3、
      ColdRestart×1、rehydration×1；socialware 1：SettlementRecoveryOnRestart）— fail-before/pass-after
- [ ] 防复活回归通过：被 regenesis/tombstone 的 worker/session 冷重启后仍 denied（重启 ≠ 重建，绝不 re-mint）
- [ ] 无新增红；`mix gate.arch` 0 failures；`mix ezagent.uri_query.scan` 0 violations
- [ ] 完整 #189 一次 codex 对抗过审 → 一次合入 main

## Handoff prompt（agent 实派版本，节选核心约束）

> The FINAL step of the #189 identity-plane fix: the CUTOVER that makes the 9 `holder_revoked`
> reds go GREEN. Work on `fix/189-identity-plane-p2` (write-plane foundation done:
> `Store` guarded active-transition = active ⇔ current-valid `:self_license` verified fresh via
> `Authority.verify_against_current` under a FOR SHARE authority-generation lock, in-txn;
> `fleet_parity` bidirectional barrier; `authenticated_holders` closed classification;
> `open(:existed)` empty-history fail-closed — Allen confirmed SAFE as-is, do NOT change).
>
> SCOPE: (1) **Read-flip** — the principal-axis cap read (`EntityCaps.load_persisted/1` /
> whatever `Cap.Authorize.principal_current?` consults via `read_held_caps`) consults
> `Store.fetch_durable_caps/1` as AUTHORITATIVE, legacy fallback ONLY for an absent row
> (a present non-active row is authoritative-empty, never falls back); gen-gated.
> (2) **Ephemeral durable-identity (THE substantive fix)** — the ephemeral worker/Session mint
> their self-license into the durable store ONCE on genuine first creation (`:created`, no prior
> durable row); at restart the durable store row itself is the ever-created signal →
> `create_freshness` = `:existed` → `open(:existed)` reads durable authority + the durable
> self-license → self-dispatch passes. A `tombstoned`/revoked row ⇒ stays denied (NOT re-minted).
> (3) gen-gated re-read + tombstone-guard.
>
> HARD ANTI-RESURRECTION INVARIANT: a revoked (regenesis'd) or tombstoned worker/session MUST
> stay denied across restart — restart ≠ re-creation. Add a regression proving it.
> Fleet-parity barrier = the documented prod-cutover precondition (write-quiescence)。
> Gates: `mix gate.arch`（684 基线）+ `mix ezagent.uri_query.scan` 本地过；allowlist/baseline
> 变更须带 justification；umbrella 测试从根目录以 `/test` 子路径跑。
