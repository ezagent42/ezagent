defmodule EzagentCore.Invariants.AuthorizeChokepointRatchetTest do
  @moduledoc """
  Anti-bypass authorization RATCHET gate (protects the concurrent-dev window
  while the #195 unified-generation-revocation program lands on a branch).

  ## Why this gate exists

  The #195 program (`docs/superpowers/plans/2026-07-20-unified-generation-\
  revocation-and-authorize.md`) migrates EVERY authority-use site onto ONE
  `Ezagent.Cap.authorize/3` chokepoint (the F-1 facade, `#1493`). Its final
  **Z-1** gate proves — empty-allowlist — that no site bypasses `authorize/3`.
  But Z-1 lands LAST. During the days #195 is developed on its branch, other
  PRs merging to `main` can introduce NEW authorization bypasses (new bare-match
  verifies, new raw cap-verify calls, new `IdentityCaps.load`/`read_held_caps`/
  `list_caps_for` cap-obtaining consumers) that go uncaught until Z-1 lands red.

  This is a **RATCHET** version of Z-1: it FREEZES the current set of
  authority-use sites (allowlist == today's `main` reality → GREEN now) and
  FAILS on any NEW site not in the allowlist. The allowlist may only SHRINK.
  When #195 migrates a class onto `authorize/3`, delete the freed entries here;
  when Z-1 lands, ratchet every seeded entry to `[]`.

  ## What it scans (the concrete bypass patterns, per the plan's anchor table)

  Each `@probes` entry greps `apps/*/lib/**/*.ex` for one AUTHORITY-USE shape
  that is NOT the `Ezagent.Cap.authorize/3` chokepoint:

    * **raw target-axis verify** outside the facade — `verify_against_current`,
      `valid_for_target?`, the in-dispatch `Cap.Verifier.authorize`/`verify_cap`;
    * **bare-matches bypass engines** — `Kind.default_holds_cap?/2`,
      `Identity.caps_authorize?/2`, `Capability.Authorization.authorizes?/2`
      (these three, named in the plan `kind.ex:288-297` / `identity.ex:303` /
      `authorization.ex:24-29`, are the dormant-cap bypasses F-2 routes through
      `authorize/3`);
    * **cap-obtaining consumers** — `IdentityCaps.load`/`load_persisted`,
      `read_held_caps`, `Identity.list_caps_for`.

  ## ACCESS vs GRANT/ADMIN classification (Phase F "Scope discipline")

  The plan classifies each authz site as **ACCESS-to-a-target** (in-scope: must
  route through `authorize/3`) vs **GRANT-side / admin-definition** (exempt —
  unification only). Only ACCESS is required for the guarantee. Each allowlist
  entry below is tagged:

    * `# home:`  — the chokepoint / primitive / definition module where the
      pattern LEGITIMATELY lives (permanent exemption — this IS `authorize/3`
      and the primitives it is built from).
    * `# ACCESS:` — a real access-side bypass that #195 Phase F must migrate
      onto `authorize/3` (Z-1 drives these to `[]`).
    * `# GRANT/idempotency/ctx/display:` — a reviewed exemption (grant-path,
      grant-idempotency read, ctx-construction for the credential cascade, or
      operator/CLI display). Frozen so a NEW such consumer is still caught for
      review, but not an ACCESS bypass.

  The point of the RATCHET is that EVERY new occurrence — ACCESS or not — trips
  the gate and forces a reviewer decision (route through `authorize/3`, or add a
  tagged allowlist entry). Perfection of the ACCESS/GRANT split is Z-1's job.

  ## Scope note (owed to Z-1)

  Bare `Capability.matches?/2` is intentionally NOT probed here — it is already
  gated by `EzagentCore.Invariants.CapCheckOnlyAtChokepointTest` (probe `:p3`,
  broad-dir allowlist). This gate covers the bare-matches CLASS via the three
  named engines instead. A brand-new bare-match engine that calls
  `Capability.matches?/2` directly inside a directory `:p3` already allows is
  caught tightly by neither gate today — that tightening is owed to Z-1.

  Mirrors `CapCheckOnlyAtChokepointTest` (`@probes`, `assert offenders == []`,
  `allowed_path?`) and `check_invariant_10`'s presence tripwire.
  """

  use ExUnit.Case, async: true

  # Z-1 migration debt is permanently empty. Legitimate primitive homes and
  # reviewed non-ACCESS consumers are classified separately per probe; they are
  # not an allowlist for bypass debt.
  @allowlist []
  @scope_tuple_tags [:within_session, :within_workspace, :spawned_by]
  @probes [
    # ── raw / cached target-axis verify OUTSIDE the authorize/3 facade ──────
    %{
      id: :raw_verify_against_current,
      desc:
        "Cap.Authority.verify_against_current/3 (the fresh-read revocation basis) " <>
          "called outside the authorize/3 chokepoint — a raw target-axis verify " <>
          "that skips the principal (holder-license) gate",
      pattern: ~r/verify_against_current/,
      reviewed_paths: [
        # home: the F-1 primitive, its public facade, and the chokepoint.
        "apps/ezagent_core/lib/ezagent/cap/authority.ex",
        "apps/ezagent_core/lib/ezagent/cap.ex",
        "apps/ezagent_core/lib/ezagent/cap/authorize.ex",
        # home: G-3's principal-axis gate. IdentityCaps.load(holder) validates
        # the holder's independently stored self-license against the current
        # holder authority before authorize/3 considers inline candidates.
        "apps/ezagent_domain_identity/lib/ezagent/identity_caps.ex",
        # #189 PR-2: the identity-caps store's WRITE-boundary resurrection guard
        # runs the SAME G-3 principal-axis check (`verify_against_current` of the
        # mirrored self-license vs the holder's current generation) so a stale
        # post-revocation license can never be written `active`. Reviewed, not an
        # authz decision — reads stay legacy in PR-2; this only decides the
        # durable row's status. Mirrors the identity_caps.ex home above.
        "apps/ezagent_domain_identity/lib/ezagent/identity_caps/store.ex",
        # P3 (cap-revocation hardening): `caps_match?/2`'s per-call TARGET-axis
        # re-verify. NOT a principal-gate bypass — the principal gate runs
        # INSIDE `IdentityCaps.load/1` (its `verified/2` G-3 self-license check
        # loads a gen-bumped holder EMPTY), which every caller passes through;
        # this call only re-checks each shape-matching artifact against its
        # target's CURRENT generation (the same target gate authorize/3's
        # `verified_candidate?/2` applies), so a target regenesis AFTER the
        # load denies. Ordered after `matches?/2` so the batch caller
        # (`Domain.Agent.read_credential_statuses/3`, SPEC §6.3) stays
        # O(authorized-caps) — routing through full `authorize/3` instead
        # would reload the holder store per candidate (O(agents×caps)).
        "apps/ezagent_domain_identity/lib/ezagent/identity.ex"
      ]
    },
    %{
      id: :cached_valid_for_target,
      desc:
        "Cap.valid_for_target?/2 (#1477 CACHED-state verify) called outside its " <>
          "sanctioned grant-idempotency use — per plan DECISION #2 this reads the " <>
          "target's stale cached authority and is NOT a revocation basis for ACCESS",
      pattern: ~r/valid_for_target\?\(/,
      reviewed_paths: [
        # home: definition + the public facade.
        "apps/ezagent_core/lib/ezagent/cap.ex",
        # GRANT/idempotency: `already_authorized?/6` checks whether the member
        # already holds a valid cap before RE-granting (grant-idempotency, the
        # one #1477 use the plan keeps). Not an ACCESS gate.
        "apps/ezagent_domain_session/lib/ezagent/behavior/session/membership.ex"
      ]
    },
    %{
      id: :in_dispatch_verifier,
      desc:
        "Cap.Verifier.authorize/5 or verify_cap/5 (the in-dispatch verifier) " <>
          "called outside the dispatch runtime + the grant path — a 2nd verify " <>
          "engine outside the authorize/3 facade",
      pattern: ~r/Verifier\.authorize\(|verify_cap\(/,
      reviewed_paths: [
        # home: the verifier itself + the sanctioned dispatch caller (runtime
        # step 5.5). F-1 routes verify_cap's per-cap filter through authorize/3.
        "apps/ezagent_core/lib/ezagent/cap/verifier.ex",
        "apps/ezagent_actor/lib/ezagent/kind/runtime.ex",
        # home: the §3.4 AuthzPort adapter — the config-resolved delegation the
        # runtime's step-5.5 call now goes through (C5; the literal verifier
        # call moved here from runtime.ex).
        "apps/ezagent_core/lib/ezagent/kind/adapters/authz_adapter.ex",
        # GRANT: the grant path verifies the GRANTOR's grant cap (grant-side,
        # exempt — unification only).
        "apps/ezagent_core/lib/ezagent/cap/grant.ex"
      ]
    },

    # ── bare-matches bypass engines (the 3 the plan names for F-2) ──────────
    %{
      id: :bare_match_default_holds_cap,
      desc:
        "Kind.default_holds_cap?/2 (bare-matches BYPASS 1 — slice) called " <>
          "outside its engine home; a new caller spreads the dormant-cap bypass " <>
          "F-2 must route through authorize/3 (plan: kind.ex:288-297)",
      pattern: ~r/default_holds_cap\?\(/,
      reviewed_paths: [
        # home: the engine (definition + internal holds_cap?/2 dispatch call).
        # C5 §3.4 — the engine RELOCATED from kind.ex to the core spine
        # `Ezagent.Cap.HoldsCap`; kind.ex keeps only the port delegates.
        "apps/ezagent_actor/lib/ezagent/kind.ex",
        "apps/ezagent_core/lib/ezagent/cap/holds_cap.ex",
        # home: the §3.4 AuthzPort adapter — the config-resolved delegation
        # the Kind delegates reach the engine through.
        "apps/ezagent_core/lib/ezagent/kind/adapters/authz_adapter.ex",
        # home: the §3.4 AuthzPort behaviour — the @callback declaration, not
        # a call site.
        "apps/ezagent_actor/lib/ezagent/kind/ports/authz_port.ex",
        # ctx/comment: a `# default_holds_cap?(:vm_internal)` doc reference in the
        # trusted-ambient-caller note, not a call.
        "apps/ezagent_domain_workspace/lib/ezagent/workspace.ex"
      ]
    },
    %{
      id: :bare_match_caps_authorize,
      desc:
        "Identity.caps_authorize?/2 (bare-matches BYPASS 3 — identity) called " <>
          "outside its home; F-2 routes this onto authorize/3 (plan: identity.ex:303)",
      pattern: ~r/caps_authorize\?\(/,
      reviewed_paths: [
        # home: the engine definition.
        "apps/ezagent_domain_identity/lib/ezagent/identity.ex",
        # ACCESS: agent-config / agent-domain / workspace-read / world consumers
        # that decide access on a bare match — F-2 migrates each to authorize/3.
        "apps/ezagent_domain_agent/lib/ezagent/agent/config.ex",
        "apps/ezagent_domain_agent/lib/ezagent/domain/agent.ex",
        "apps/ezagent_domain_workspace/lib/ezagent/workspace/workspace_reads.ex",
        "apps/ezagent_plugin_world/lib/ezagent/world/identity_data.ex"
      ]
    },
    %{
      id: :bare_match_authorization_authorizes,
      desc:
        "Capability.Authorization.authorizes?/authorizing_cap (bare-matches " <>
          "BYPASS 2 — preflight) called outside its home; F-2 routes this onto " <>
          "authorize/3 (plan: authorization.ex:24-29)",
      pattern: ~r/Authorization\.authorizes\?\(|Authorization\.authorizing_cap\(/,
      reviewed_paths: [
        # ACCESS: pty-access + session admission + orchestrator-tool preflights
        # that gate access on a bare preflight match — F-2 migrates each.
        "apps/ezagent_domain_pty/lib/ezagent_domain_pty/access.ex",
        "apps/ezagent_domain_session/lib/ezagent/session_config/admission.ex",
        "apps/ezagent_domain_session/lib/ezagent/orchestrator/tools.ex",
        "apps/ezagent_domain_session/lib/ezagent/orchestrator/tools/member_template.ex",
        "apps/ezagent_domain_session/lib/ezagent/orchestrator/tools/participants.ex"
      ]
    },

    # ── cap-obtaining consumers (must source from the fail-closed load) ─────
    %{
      id: :cap_obtaining_entitycaps_load,
      desc:
        "IdentityCaps.load/1 or load_persisted/1 consumed outside its home — the " <>
          "principal-axis cap-load path (G-3 self-license gate site). A new " <>
          "consumer must source caps from this fail-closed load, never re-derive",
      pattern: ~r/IdentityCaps\.load/,
      reviewed_paths: [
        # home: the fail-closed cap-load path itself.
        "apps/ezagent_domain_identity/lib/ezagent/identity_caps.ex",
        # ctx/GRANT: identity-domain internals that load a principal's caps to
        # BUILD authority/cascade/absorb ctx (grant-side + admin-definition).
        "apps/ezagent_domain_identity/lib/ezagent/entity.ex",
        "apps/ezagent_domain_identity/lib/ezagent/entity/user.ex",
        "apps/ezagent_domain_identity/lib/ezagent/identity.ex",
        "apps/ezagent_domain_identity/lib/ezagent/identity/admin_authority.ex",
        "apps/ezagent_domain_identity/lib/ezagent/identity/authority.ex",
        "apps/ezagent_domain_identity/lib/ezagent/identity/cap_absorb_await.ex",
        "apps/ezagent_domain_identity/lib/ezagent/identity/cascade.ex",
        "apps/ezagent_domain_identity/lib/ezagent/identity/operator_reads.ex",
        # ctx: session membership / reconcile / orchestrator load owner caps to
        # build the credential-cascade spawn ctx (same class as p6 exemptions).
        "apps/ezagent_domain_session/lib/ezagent/behavior/session/member_cap.ex",
        "apps/ezagent_domain_session/lib/ezagent/behavior/session/membership.ex",
        "apps/ezagent_domain_session/lib/ezagent/behavior/session/reconcile.ex",
        # membership projection: add_self deliberately reads the persisted
        # holder artifact to avoid a cross-Kind activation deadlock, then runs
        # the shared generation-aware membership predicate before writing.
        "apps/ezagent_domain_session/lib/ezagent/behavior/session/self_add.ex",
        "apps/ezagent_domain_session/lib/ezagent/entity/session/orchestrator/caps.ex",
        "apps/ezagent_domain_session/lib/ezagent/session_config.ex",
        "apps/ezagent_domain_session/lib/ezagent/session/member_cap_migration.ex",
        # ACCESS: read-plane predicates that decide visibility off loaded caps —
        # M-1 folds the membership predicate into authorize/3.
        "apps/ezagent_domain_session/lib/ezagent/session/membership_predicate.ex",
        "apps/ezagent_domain_session/lib/ezagent/socialware/board_provision.ex",
        "apps/ezagent_domain_socialware/lib/ezagent/socialware/anon_admission.ex",
        "apps/ezagent_domain_socialware/lib/ezagent/socialware/session_reads.ex",
        "apps/ezagent_domain_workspace/lib/ezagent/workspace/workspace_reads.ex",
        "apps/ezagent_plugin_world/lib/ezagent/world/presenter_caps.ex",
        "apps/ezagent_plugin_world/lib/ezagent/world/user_data.ex",
        # ctx/display: CLI + web load the caller's caps to build a dispatch ctx.
        "apps/ezagent_cli/lib/ezagent_cli/exec.ex",
        "apps/ezagent_domain_agent/lib/ezagent/domain/agent.ex",
        "apps/ezagent_web/lib/ezagent_web/controllers/api_v1_controller.ex",
        "apps/ezagent_web/lib/ezagent_web/live_auth.ex"
      ]
    },
    %{
      id: :cap_obtaining_read_held_caps,
      desc:
        "read_held_caps/1 (the dependency-inverted holder-cap source) consumed " <>
          "outside the authorize/3 facade + its loader/definition home",
      pattern: ~r/read_held_caps\(/,
      reviewed_paths: [
        # home: the loader seam behaviour, the facade, the public delegator, and
        # the concrete AuthorityLoader impl (Identity.read_held_caps/1).
        "apps/ezagent_core/lib/ezagent/cap/authority_loader.ex",
        "apps/ezagent_core/lib/ezagent/cap/authorize.ex",
        "apps/ezagent_core/lib/ezagent/cap.ex",
        "apps/ezagent_domain_identity/lib/ezagent/identity.ex",
        # ctx/display: CLI dispatch reads the caller's held caps to build the ctx.
        "apps/ezagent_cli/lib/ezagent_cli/dispatch.ex"
      ]
    },
    %{
      id: :cap_obtaining_list_caps_for,
      desc:
        "Identity.list_caps_for/1 consumed outside its home — a cap-obtaining " <>
          "read; a new consumer must go through the fail-closed load / authorize/3",
      pattern: ~r/list_caps_for\(/,
      reviewed_paths: [
        # home: the definition.
        "apps/ezagent_domain_identity/lib/ezagent/identity.ex",
        # ctx/display/idempotency: entity + session-domain + workspace read the
        # subject's OWN caps to build spawn ctx / idempotency-skip a grant /
        # display — the exact class p6 of CapCheckOnlyAtChokepointTest exempts.
        "apps/ezagent_domain_identity/lib/ezagent/entity.ex",
        "apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator.ex",
        "apps/ezagent_domain_session/lib/ezagent/behavior/session/membership.ex",
        "apps/ezagent_domain_session/lib/ezagent/behavior/turn.ex",
        "apps/ezagent_domain_session/lib/ezagent/entity/session.ex",
        "apps/ezagent_domain_ui/lib/ezagent_domain_ui/session_view.ex",
        "apps/ezagent_domain_workspace/lib/ezagent/workspace.ex",
        "apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/sender_resolver.ex",
        # display: operator CLI (mix task) cap listing — admin-definition, not
        # ACCESS. Frozen (a NEW mix bypass is still caught), per advisor #3.
        "apps/ezagent_domain_external_mirror/lib/mix/tasks/ezagent_external_mirror_cli.ex"
      ]
    },
    %{
      id: :low_level_recredential,
      desc:
        "a low-level signer/issuer used outside the generation-gated cap homes — " <>
          "a post-bump path could re-arm a revoked principal",
      pattern:
        ~r/Authority\.sign\(|Authority\.issue_current\(|Authority\.issue_self_license_current\(|Cap\.Grant\.issue\(|Cap\.Grant\.issue_self_license\(/,
      reviewed_paths: [
        # homes: the target authority signer and its frozen grant intent.
        "apps/ezagent_core/lib/ezagent/cap/authority.ex",
        "apps/ezagent_core/lib/ezagent/cap/grant.ex",
        # the TWO sanctioned, create-gated self-license minters (mirrors the
        # self-license-construction ratchet): `issue_self_license_current` is the
        # reserved-action issuer they call. Any THIRD caller is an un-gated
        # re-credential path and trips this probe.
        "apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex",
        "apps/ezagent_domain_identity/lib/ezagent/behavior/self_license.ex"
      ]
    },
    %{
      id: :public_self_license_minter,
      desc:
        "the public Identity self-license minter `Ezagent.ActionSet.Identity." <>
          "mint_self_license/2` invoked cross-module outside `AdminKeyRotation` — " <>
          "another external caller is an un-gated re-credential " <>
          "path the whole-file `identity.ex` allowlist would miss. Matches the " <>
          "QUALIFIED `Identity.mint_self_license(` call form (identity.ex's own " <>
          "unqualified internal calls + unrelated same-named private helpers, e.g. " <>
          "`session_self_license_migration.ex`, are intentionally not matched).",
      pattern: ~r/Identity\.mint_self_license\(/,
      reviewed_paths: [
        # the MANUAL admin key-rotation operator command (atomic rotate + re-mint).
        "apps/ezagent_domain_identity/lib/ezagent/identity/admin_key_rotation.ex"
      ]
    }
  ]

  @umbrella_root Path.expand("../../../..", __DIR__)

  test "Z-1: no authority-use bypass outside the authorize/3 chokepoint" do
    all_files = Path.wildcard(Path.join(@umbrella_root, "apps/*/lib/**/*.ex"))

    offenders =
      for probe <- @probes,
          path <- all_files,
          not reviewed_path?(path, probe.reviewed_paths),
          content = File.read!(path),
          Regex.match?(probe.pattern, content),
          do:
            "[#{probe.id}] #{probe.desc}\n      @ #{rel(path)}\n      pattern: #{inspect(probe.pattern)}"

    assert @allowlist == []

    assert offenders == [],
           """
           Anti-bypass RATCHET tripped — a NEW authority-use site was introduced \
           OUTSIDE the `Ezagent.Cap.authorize/3` chokepoint:

           #{Enum.join(offenders, "\n\n")}

           This gate freezes the #195-era set of authority-use sites so no NEW
           bypass merges to `main` while the unified-revocation program lands on
           its branch. Do ONE of:

             1. Route the new site through `Ezagent.Cap.authorize/3` (the single
                chokepoint — runs the principal + target-generation gates), OR
             2. If it is a reviewed GRANT-side / admin-definition / ctx-construction
                exemption, add a `# ACCESS:`/`# GRANT:`-tagged full-path entry to the
                matching probe's allowlist above (the allowlist may only GROW for a
                genuinely-new non-ACCESS site, and only SHRINK for ACCESS sites).

           See docs/superpowers/plans/2026-07-20-unified-generation-revocation-and-\
           authorize.md (Phase F "Scope discipline" + Task Z-1).
           """
  end

  test "presence tripwire: the authorize/3 chokepoint still runs both gates" do
    # Mirror of check_invariant_10 — fail the build if the facade is gutted so
    # the ratchet can't be defeated by hollowing out `authorize/3` itself.
    authorize_src =
      File.read!(Path.join(@umbrella_root, "apps/ezagent_core/lib/ezagent/cap/authorize.ex"))

    assert authorize_src =~ "verify_against_current",
           "authorize/3 lost its target-gate call (verify_against_current) — the " <>
             "chokepoint no longer verifies candidate caps against the current authority."

    assert authorize_src =~ "read_held_caps",
           "authorize/3 lost its dependency-inverted principal (holder) gate " <>
             "(read_held_caps) — a revoked holder's inline caps could now authorize."
  end

  test "Z-1/MF4: target-generation verification never reads process-local authority" do
    authority = source("apps/ezagent_core/lib/ezagent/cap/authority.ex")

    verify_against_current =
      authority
      |> String.split("def verify_against_current(", parts: 2)
      |> List.last()
      |> String.split("defp current_key_id(", parts: 2)
      |> List.first()

    refute verify_against_current =~ "Process.get"
    refute verify_against_current =~ "current_target?"
    assert verify_against_current =~ "current_key_id(target)"
    assert verify_against_current =~ "AuthorityCache.public_key"
  end

  test "Z-1/MF9: no production access credential constructs an unsigned scope tuple" do
    offenders =
      Path.wildcard(Path.join(@umbrella_root, "apps/*/lib/**/*.ex"))
      |> Enum.reject(&String.contains?(&1, "/e2e/scenarios/"))
      |> Enum.flat_map(&scope_tuple_cap_constructors/1)

    assert @allowlist == []

    assert offenders == [],
           """
           unsigned scope-tuple access-cap constructors (empty allowlist):
           #{Enum.map_join(offenders, "\n", &"  - #{&1}")}

           Scope tuples are grant bounds only. Production access credentials
           must target a concrete URI and pass Cap.authorize/3.
           """

    authority = source("apps/ezagent_core/lib/ezagent/cap/authority.ex")
    authorize = source("apps/ezagent_core/lib/ezagent/cap/authorize.ex")
    cap = source("apps/ezagent_core/lib/ezagent/cap.ex")

    assert authority =~ "def target_uri(%Capability{instance: %URI{} = instance})"
    assert authority =~ "{:error, :concrete_target_required}"
    assert authorize =~ "{:error, :concrete_target_required} -> false"
    assert cap =~ "instance: %URI{}"
  end

  test "Z-1: self-license construction is confined to the sanctioned gated minters, and ordinary grants reject it" do
    constructor_hits =
      Path.wildcard(Path.join(@umbrella_root, "apps/*/lib/**/*.ex"))
      |> Enum.flat_map(&self_license_cap_constructors/1)

    # The two runtime self-license minters remain create-gated.
    #   1. `ActionSet.Identity` (User/Agent) — create-gated;
    #   2. `ActionSet.SelfLicense` carrier (the Session) — create-gated.
    # Any third constructor, or an un-gated one, fails this.
    constructor_files =
      constructor_hits
      |> Enum.map(&(&1 |> String.split(":") |> hd()))
      |> Enum.sort()
      |> Enum.uniq()

    assert constructor_files == [
             "apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex",
             "apps/ezagent_domain_identity/lib/ezagent/behavior/self_license.ex"
           ]

    # Z-1 TIGHTENING (#189 PR-3, disposition item): assert the EXACT HIT COUNT,
    # not just the deduplicated file set. The previous filename-dedup check would
    # have passed a SECOND (hidden) constructor added to an already-approved file
    # — exactly one create-gated `Capability.cap(_, _, :self_license, _, _)` in
    # each runtime file and no maintenance bypass ⇒ two hits.
    assert length(constructor_hits) == 2

    identity = source("apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex")
    self_license = source("apps/ezagent_domain_identity/lib/ezagent/behavior/self_license.ex")

    cap = source("apps/ezagent_core/lib/ezagent/cap.ex")
    grant = source("apps/ezagent_core/lib/ezagent/cap/grant.ex")

    # Minters 1+2 are create-gated — never an arbitrary runtime mint.
    assert identity =~
             "maybe_mint_self_license(caps, %{create_freshness: :created, uri: %URI{} = uri})"

    assert self_license =~ "def create(%{create_freshness: :created, uri: %URI{} = uri})"

    assert cap =~ "%Capability{action: :self_license}"
    assert cap =~ "do: {:error, :reserved_action}"
    assert grant =~ "do: {:error, :reserved_action}"
  end

  test "Z-1: every inline caller context carries an explicit authenticated holder" do
    offenders =
      Path.wildcard(Path.join(@umbrella_root, "apps/*/lib/**/*.ex"))
      |> Enum.flat_map(&missing_authenticated_holders/1)

    assert @allowlist == []

    assert offenders == [],
           """
           authorization contexts missing `authenticated_principal` (empty allowlist):
           #{Enum.map_join(offenders, "\n", &"  - #{&1}")}

           Thread the authenticated holder explicitly from the external boundary.
           Do not fall back to `ctx.caller`; only `:vm_internal` ambient contexts
           are exempt from carrying an identity principal.
           """
  end

  test "Z-1: the three compatibility authorization engines delegate to authorize/3" do
    sources = [
      # C5 §3.4 — the holds-cap engine RELOCATED from kind.ex to the core
      # spine `Ezagent.Cap.HoldsCap` (kind.ex keeps only port delegates).
      source("apps/ezagent_core/lib/ezagent/cap/holds_cap.ex"),
      source("apps/ezagent_core/lib/ezagent/capability/authorization.ex"),
      source("apps/ezagent_domain_identity/lib/ezagent/identity.ex")
    ]

    offenders = Enum.reject(sources, &String.contains?(&1, "Ezagent.Cap.authorize"))
    assert offenders == []
  end

  defp reviewed_path?(path, reviewed_paths) do
    Enum.any?(reviewed_paths, fn reviewed -> String.contains?(path, reviewed) end)
  end

  defp missing_authenticated_holders(path) do
    with {:ok, ast} <- Code.string_to_quoted(File.read!(path)) do
      {_ast, offenders} =
        Macro.prewalk(ast, [], fn
          {:%{}, map_meta, entries} = node, acc ->
            caller = literal_map_value(entries, :caller)
            holder = literal_map_value(entries, :authenticated_principal)

            authorization_context? =
              literal_map_value(entries, :caps) != :missing or
                literal_map_value(entries, :reply) != :missing or
                literal_map_value(entries, :cap_delivery_producer) != :missing

            if caller != :missing and caller != :vm_internal and authorization_context? and
                 holder == :missing do
              line = Keyword.get(map_meta, :line, 1)
              {node, ["#{rel(path)}:#{line}" | acc]}
            else
              {node, acc}
            end

          node, acc ->
            {node, acc}
        end)

      Enum.reverse(offenders)
    else
      {:error, {_line, error, token}} ->
        ["#{rel(path)}: parse failed: #{inspect(error)} #{inspect(token)}"]
    end
  end

  defp scope_tuple_cap_constructors(path) do
    with {:ok, ast} <- Code.string_to_quoted(File.read!(path)) do
      {_ast, offenders} =
        Macro.prewalk(ast, [], fn
          {:%, _, [module_ast, {:%{}, meta, entries}]} = node, acc ->
            instance = literal_map_value(entries, :instance)

            if capability_module?(module_ast) and scope_tuple?(instance) do
              {node, ["#{rel(path)}:#{Keyword.get(meta, :line, 1)}" | acc]}
            else
              {node, acc}
            end

          {{:., _, [module_ast, :cap]}, meta, args} = node, acc ->
            instance = Enum.at(args, 3, :missing)

            if capability_module?(module_ast) and scope_tuple?(instance) do
              {node, ["#{rel(path)}:#{Keyword.get(meta, :line, 1)}" | acc]}
            else
              {node, acc}
            end

          node, acc ->
            {node, acc}
        end)

      Enum.reverse(offenders)
    else
      {:error, {_line, error, token}} ->
        ["#{rel(path)}: parse failed: #{inspect(error)} #{inspect(token)}"]
    end
  end

  defp self_license_cap_constructors(path) do
    with {:ok, ast} <- Code.string_to_quoted(File.read!(path)) do
      {_ast, offenders} =
        Macro.prewalk(ast, [], fn
          {{:., _, [module_ast, :cap]}, meta, args} = node, acc ->
            if capability_module?(module_ast) and Enum.at(args, 2, :missing) == :self_license do
              {node, ["#{rel(path)}:#{Keyword.get(meta, :line, 1)}" | acc]}
            else
              {node, acc}
            end

          node, acc ->
            {node, acc}
        end)

      Enum.reverse(offenders)
    else
      {:error, {_line, error, token}} ->
        ["#{rel(path)}: parse failed: #{inspect(error)} #{inspect(token)}"]
    end
  end

  defp capability_module?(module_ast) do
    Macro.to_string(module_ast) in ["Capability", "Ezagent.Capability"]
  end

  defp scope_tuple?({tag, _uri_ast}) when tag in @scope_tuple_tags, do: true
  defp scope_tuple?(_instance), do: false

  defp literal_map_value(entries, key) do
    Enum.find_value(entries, :missing, fn
      {^key, value} -> value
      _entry -> nil
    end)
  end

  defp source(relative), do: File.read!(Path.join(@umbrella_root, relative))

  defp rel(path), do: Path.relative_to(path, @umbrella_root)
end
