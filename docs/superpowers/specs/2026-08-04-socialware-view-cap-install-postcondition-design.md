# Socialware View-Cap Install Postcondition Design

Date: 2026-08-04

## Problem

A session can finish socialware installation without all existing confirmed user
members holding the installed definition's declared-view capabilities.

The failure is reproducible when the initial synchronous member view-cap grant
times out after other installation work has committed. A later idempotent retry
can observe the role agents as already materialized, finish the remaining work,
and resolve the durable installation obligation without revisiting the missing
member view-cap. The session then contains the hello definition and a surface,
but `SessionView.authorize_view/3` rejects the caller and World omits the Page
view.

This was observed on `hello-codex-2`, `hello-codex-3`, and
`codex-template-1`: their install obligations required two attempts, while their
`hello_render` caps were absent until a later manual `MemberBackfill` call.

## Goal

Treat declared-view capability convergence for existing confirmed user members
as a postcondition of successful socialware installation.

An installation obligation may resolve only after every eligible existing
member holds every declared-view capability for the session's installed
definitions.

## Non-goals

- No hello-specific branch or Page-specific repair path.
- No new capability grant chokepoint.
- No periodic database repair scanner or second source of truth.
- No permission expansion for agents, anonymous users, removed members, or
  non-members.
- No change to socialware role materialization or credential admission.

## Design

### Result-aware view-cap convergence

The existing membership capability funnel remains the only grant implementation.
It will expose a strict, result-aware path for declared-view grants while
preserving the current best-effort API used by navigation and join affordances.

The strict path:

1. Verifies that the target is a confirmed user and a current tier-1 member.
2. Enumerates the session's declared view actions through
   `Socialware.Installation.declared_view_actions/1`.
3. Reuses the existing exact-identity and current target-signature check.
4. Skips capabilities that are already valid.
5. Grants missing capabilities through the existing
   `Ezagent.Identity.Grant.grant_cap_via_router/4` call site.
6. Returns an error if any required grant fails instead of degrading that error
   to `:ok`.

This refactor must not add another production capability constructor or grant
dispatch site.

### Installation postcondition

After role materialization and the existing installation writes succeed,
`Socialware.SessionInstaller` will converge declared-view capabilities for all
eligible members already present in the session.

Member enumeration uses the session membership source of truth. The postcondition
filters to confirmed user URIs; agents and anonymous users retain their existing
provisioning rules.

If convergence fails, the installer returns an error. The durable
`SocialwareInstallObligation` therefore remains retryable and is not marked
`resolved`. On the next retry, already valid grants are skipped and only missing
capabilities are attempted.

### UI convergence

A successful capability store emits the existing identity slice-change signal.
World's current identity-change handling reloads presenter caps and refreshes the
current route, so an already-mounted conversation receives a new `world:state`
whose caller-authorized `views` includes the newly available view. No
hello-specific browser event or World branch is added.

## Error handling

- A transient grant timeout keeps the durable installation obligation retryable.
- A successful partial grant is safe: retries are exact-identity idempotent.
- A stale roster entry is not sufficient authority; the existing current-member
  entitlement check remains mandatory.
- Invalid, unconfirmed, anonymous, agent, removed, or non-member entries do not
  receive new capabilities.
- Persistent failures remain visible through the existing obligation error,
  logs, and telemetry.

## Tests

The implementation follows red-green TDD.

1. A regression test creates a socialware session with an existing confirmed
   user, forces the first declared-view grant to fail, and verifies installation
   does not report success or resolve its obligation.
2. The retry test removes the injected failure, reruns installation, and verifies
   the obligation resolves only after `SessionView.authorize_view/3` succeeds.
3. The retry test verifies already successful grants are not duplicated.
4. Eligibility tests verify agents, anonymous users, removed members, and
   non-members receive no new view capabilities.
5. A World projection assertion verifies the caller-visible view list contains
   the declared view after convergence.
6. Existing member-backfill, socialware-install sweeper, SessionInstaller, and
   view-authorization suites remain green.

## Acceptance criteria

- A newly created hello session exposes Page without manual database repair.
- A first-attempt view-cap timeout cannot result in a resolved installation with
  a missing view capability.
- Retrying converges the missing capability without duplicating valid grants.
- The fix applies to every socialware declared view and contains no hello-specific
  production condition.
- An already-open World conversation refreshes to include the newly authorized
  view through the existing identity slice-change contract.
