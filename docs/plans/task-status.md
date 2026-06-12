# Task Status — AutoService v2 P0

> Updated: 2026-06-12 | Branch: `feat/autoservice-v2-merge-v2`

## Progress

| | Count |
|---|---|
| Total | 13 |
| Done | 0 |
| In Progress | 0 |
| Pending | 13 |

## P0 — Core Architecture (M0)

| ID | Name | Effort | Deps | Status |
|----|------|--------|------|--------|
| T0A.1 | CsOrchestrator Behavior | large | — | ⬜ pending |
| T0A.2 | TurnDriver | medium | T0A.1 | ⬜ pending |
| T0A.3 | Register Behavior | small | T0A.1 | ⬜ pending |
| T0A.4 | Session→SocialwareSession | small | — | ⬜ pending |
| T0A.5 | Routing + Agent reply | medium | T0A.1, T0A.3 | ⬜ pending |
| T0A.6 | OperatorLive dispatch | medium | T0A.1-3 | ⬜ pending |
| T0A.7 | api_key from env | small | — | ⬜ pending |

## P1 — PR Verified Capabilities (M1)

| ID | Name | Effort | Deps | Status |
|----|------|--------|------|--------|
| T1A.1 | TenantAdminLive | medium | T0A.1 | ⬜ pending |
| T1A.2 | Assembly.Refresh | medium | T0A.1, T0A.3 | ⬜ pending |
| T1A.3 | CR crash recovery | medium | — | ⬜ pending |
| T1A.4 | Port tests | large | T0A.1-6, T1A.1-3 | ⬜ pending |

## P2 — Enhancements (M2)

| ID | Name | Effort | Deps | Status |
|----|------|--------|------|--------|
| T2A.1 | Seed params | small | T0A.4 | ⬜ pending |
| T2A.2 | Admin nav | small | T1A.1 | ⬜ pending |
