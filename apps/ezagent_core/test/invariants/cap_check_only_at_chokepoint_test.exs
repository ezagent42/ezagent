defmodule EzagentCore.Invariants.CapCheckOnlyAtChokepointTest do
  @moduledoc """
  PR-CC-2-v2 §6 — 12 probes against cap-check leakage outside the
  dispatch step 5.5 chokepoint.

  Each probe greps `apps/*/lib/**/*.ex` for a pattern that signals a
  cap-shape inspection happening outside the dispatch chokepoint
  (`Ezagent.Kind.Runtime.handle_dispatch/4` step 5.5 via the new
  `Behavior.required_caps/0` + `Kind.holds_cap?/2` flow). Each probe
  has an allowlist of paths where the pattern is the legitimate
  implementation OR a documented exemption.

  Per SPEC §6: a single regex catches one shape; a 13th leak shape
  surfaces a 13th probe + SPEC amendment as the regression-lock
  contract.

  See `docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md` §6.
  """

  use ExUnit.Case, async: true

  @probes [
    %{
      id: :p1,
      desc: "User.admin_caps/0 revival (deleted in PR-CC-1)",
      pattern: ~r/\bUser\.admin_caps\(/,
      allowlist: ["test/support/", "test/invariants/no_admin_caps_fallback_test.exs"]
    },
    %{
      id: :p2,
      desc: "ambient %Capability{} all-wildcard construction outside catalog bootstrap",
      pattern: ~r/kind:\s*:any.*behavior:\s*:any.*instance:\s*:any.*workspace_uri:\s*:any/s,
      allowlist: [
        "apps/ezagent_core/lib/ezagent/capability.ex",
        "apps/ezagent_core/lib/ezagent/capability/parser.ex",
        "apps/ezagent_core/lib/ezagent/system_principal/catalog.ex",
        "apps/ezagent_core/lib/ezagent/system_principal.ex",
        "apps/ezagent_core/lib/mix/tasks/",
        # Identity Behavior init_slice docstring references the
        # admin-cap shape for the bootstrap path (no ambient
        # construction outside the documented admin path).
        "apps/ezagent_domain_identity/lib/ezagent/behavior/identity.ex"
      ]
    },
    %{
      id: :p3,
      desc: "Capability.matches?/2 outside chokepoint",
      pattern: ~r/Capability\.matches\?/,
      allowlist: [
        "apps/ezagent_core/lib/ezagent/",
        "apps/ezagent_domain_identity/lib/ezagent/",
        "apps/ezagent_domain_external_mirror/lib/ezagent/",
        # PR-8 (transport #53 / O-4) — the orchestrator tool OPERATIONS
        # (`Orchestrator.Tools` + `.MemberTemplate` + `.Templates`, which read
        # `matches?` for delegated-cap preflight + read-only tooling display)
        # STAY in the session domain; they are covered by this im allowlist
        # entry. The cc orchestrator dir no longer uses `matches?` (the cc
        # McpServer is a thin transport that dispatches), so it is NOT listed.
        "apps/ezagent_domain_session/lib/ezagent/",
        # Mix tasks consume matches? for CLI display.
        "apps/ezagent_domain_external_mirror/lib/mix/tasks/",
        "apps/ezagent_core/lib/mix/tasks/",
        # T2-2b — `SessionView.authorize_view/3` matches a caller's held caps
        # against a view's `<sw>_render` need. This is the SPEC-designed view-cap
        # authorization: a PROJECTION-BYPASS read (render is not a dispatch —
        # SPEC §3.2.1 "保留投影旁路读, 只把授权维度升级"), NOT a cap-gate on the
        # dispatch chokepoint. Contained to the SessionView contract file.
        "apps/ezagent_domain_ui/lib/ezagent_domain_ui/session_view.ex"
      ]
    },
    %{
      id: :p4,
      desc: "cap_subjects/0 callback declaration outside Behavior contract + impls",
      pattern: ~r/def\s+cap_subjects\b/,
      allowlist: [
        "apps/ezagent_core/lib/ezagent/behavior.ex",
        "apps/ezagent_core/lib/ezagent/behavior/",
        "apps/ezagent_domain_session/lib/ezagent/behavior/",
        "apps/ezagent_domain_external_mirror/lib/ezagent/behavior/",
        "apps/ezagent_domain_identity/lib/ezagent/behavior/",
        "apps/ezagent_domain_pty/lib/ezagent/behavior/",
        "apps/ezagent_domain_workspace/lib/ezagent/behavior/",
        "apps/ezagent_plugin_curl_agent/lib/ezagent/behavior/",
        "apps/ezagent_plugin_py/lib/ezagent/behavior/",
        "apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/behavior/",
        # P4 — the chat_feed `:pull` ExternalAdapter co-locates its cap-only
        # allow-cap behavior (`ChatFeedAdapter.Allow`, declaring `cap_subjects/0`)
        # with the adapter (plugin-isolation: the adapter owns its own bind cap).
        # Precise file allowlist keeps the cap shape contained.
        "apps/ezagent_domain_socialware/lib/ezagent/socialware/chat_feed_adapter.ex",
        "apps/ezagent_domain_socialware/lib/ezagent/socialware/external_feed_adapter.ex",
        # T2-2a — the hello socialware's cap-only view read ActionSet
        # (`HelloRender`, declaring `cap_subjects/0` for `:hello_render`) — a
        # normal Behavior impl co-located under the plugin's behavior dir, same
        # class as every other ActionSet listed above.
        "apps/ezagent_plugin_hello/lib/ezagent/behavior/",
        # S4 — the kanban-team board view's cap-only view read ActionSet
        # (`KanbanRender`, declaring `cap_subjects/0` for `:kanban_render`) —
        # the SAME class as `HelloRender` directly above (cap-only, no dispatch
        # surface; `SessionView.authorize_view/3` checks its render cap).
        # Precise FILE allowlist (not the whole kanban behavior dir — the other
        # kanban ActionSet declares via the `action/2` macro and stays probed).
        "apps/ezagent_plugin_kanban/lib/ezagent/behavior/kanban_render.ex"
      ]
    },
    %{
      id: :p5,
      desc: "CapabilityRegistry.lookup outside dispatch + LV admin display",
      pattern: ~r/CapabilityRegistry\.(?:lookup|fetch|get)\b/,
      allowlist: [
        "apps/ezagent_core/lib/ezagent/"
      ]
    },
    %{
      id: :p6,
      desc: "Identity.list_caps_for/1 outside Identity domain + LV display + tooling",
      pattern: ~r/Identity\.list_caps_for\b/,
      allowlist: [
        "apps/ezagent_domain_identity/",
        "apps/ezagent_core/lib/ezagent/kind.ex",
        # PR-8 (transport #53 / O-4): the cc McpServer no longer reads caps —
        # it is a thin transport that dispatches; the orchestrator's delegated
        # caps are reconstructed SESSION-side via the `identity.list_caps`
        # DISPATCH (not `Identity.list_caps_for`), so no cc orchestrator file
        # matches this pattern. (The session-side reconstruction goes through
        # the dispatch chokepoint, the sanctioned path.)
        # External-mirror CLI — operator-driven cap display.
        "apps/ezagent_domain_external_mirror/lib/mix/tasks/",
        # Feishu binding sender resolver — read-only inbound-binding
        # lookup (no grant/mutation, just display).
        "apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/sender_resolver.ex",
        # Session entity — chat send recipient-resolution reads
        # member caps to filter mention-gated routing. ALSO holds
        # `orchestrator_spawn_template_opts/2`, which reads the session OWNER's
        # OWN caps to BUILD the credential-cascade spawn ctx (`caps:`) — NOT a
        # cap-gate decision outside dispatch.
        "apps/ezagent_domain_session/lib/ezagent/entity/session.ex",
        # Phase3③ T7c — the per-session default-agent materialize engine reads the
        # OWNER's OWN caps to BUILD the spawn cascade ctx (`opts[:caps]`),
        # generalizing `Ezagent.Entity.Session.orchestrator_spawn_template_opts/2`
        # (allowlisted above) off the hardcoded `cc-orchestrator` role. Same class
        # as that call: a read of the owner's authority to feed the credential
        # cascade, NOT a cap-gate decision outside the dispatch chokepoint.
        "apps/ezagent_domain_agent/lib/ezagent/agent/session_agent_materialize.ex",
        # T2-2b — `SessionView.authorize_view/3` reads the caller's held caps to
        # decide view visibility (a SPEC-designed projection-bypass view-cap
        # check, SPEC §3.2.1 — NOT a dispatch-chokepoint gate). Contained to the
        # SessionView contract file (same class as the session-entity read above).
        "apps/ezagent_domain_ui/lib/ezagent_domain_ui/session_view.ex",
        # RFC #402 (Allen 2026-05-26) — the internal session creator
        # reads the creator's caps to skip a duplicate OrchestratorAdmin
        # :restart cap grant when an equivalent one already exists.
        # This is an idempotency-check on the create path (read-only
        # against the grantee's own caps), NOT a cap-gate decision
        # outside the dispatch chokepoint.
        "apps/ezagent_domain_session/lib/ezagent_domain_instance_message/session_creator.ex",
        # Transport #53 Decision C — the per-orchestrator `SessionManager`
        # GenServer RECONSTRUCTS the orchestrator's OWN delegated caps to run a
        # forwarded `tools/call` under them. It reads them via the sanctioned
        # `Identity.list_caps_for/1` (which dispatches `identity.list_caps`
        # through the chokepoint for the agent's OWN caps) — a read of the
        # caller's own delegated authority to BUILD the op ctx, NOT a cap-gate
        # decision made outside dispatch. The 4 delegated caps then gate each
        # underlying op AT the dispatch chokepoint.
        "apps/ezagent_domain_session/lib/ezagent/session/session_manager.ex",
        # #533 PR-5 — create-time Manage cap grants use the same
        # idempotency pattern in the Workspace facade: read existing
        # caps to avoid duplicate grant writes, then dispatch the
        # actual grant through Identity.
        "apps/ezagent_domain_workspace/lib/ezagent/workspace.ex",
        # First-login wizard: builds a real caller ctx for
        # Workspace.create_session/3. Same class as LV display/ctx
        # construction allowlisted for plugin LiveView.
        "apps/ezagent_web/lib/ezagent_web/live/home_live.ex",
        # Agent-owned config-evolve recovery replay (spec 2026-06-11 H3,
        # Allen-decided). Turn's `recovery_effects` reads the recorded
        # manager URI's caps to BUILD the dispatch ctx for the config-apply
        # replay; the standard manage-cap gate then re-validates AT the
        # dispatch chokepoint (still holds → apply; lost it → :unauthorized,
        # skip+log). This is ctx CONSTRUCTION feeding the chokepoint, NOT a
        # cap-gate decision outside it — same class as the home_live wizard
        # and the session_creator idempotency reads above.
        "apps/ezagent_domain_session/lib/ezagent/behavior/turn.ex",
        # Session membership grant path — `grant_join_cap/3` and
        # `do_mount_participation_caps/2` read the GRANTEE's OWN caps to skip a
        # duplicate grant (idempotency: caps carry a fresh `granted_at`, so the
        # slice MapSet never dedupes → re-grant on every navigation = `:identity`
        # slice-change churn). These reads gate ONLY whether to GRANT (both return
        # `:ok` either way; the actual grant goes through `grant_cap_via_router`);
        # they NEVER gate whether the join/action itself proceeds — that stays at
        # the dispatch chokepoint. Identical class to the session_creator +
        # workspace idempotency reads allowlisted above.
        "apps/ezagent_domain_session/lib/ezagent/behavior/session/membership.ex"
      ]
    },
    %{
      id: :p7,
      desc: "Identity.grant_cap/3 outside Identity Behavior + admin LV + mix tasks",
      pattern: ~r/Identity\.grant_cap\b/,
      allowlist: [
        "apps/ezagent_domain_identity/lib/ezagent/",
        "apps/ezagent_domain_workspace/lib/mix/",
        # Phase3③ T7a — the default-agent recipe-cap grant ENGINE moved out of the
        # boot-time `DefaultAgentSeed` (a non-deliberate after_boot entry, p7's
        # exact target) into the sanctioned OPERATOR/materialize mix task
        # `Mix.Tasks.Ezagent.Agent.GrantRecipeCaps`. Same sanctioned mix-task
        # category as the `ezagent_domain_workspace/lib/mix/` entry above (p7 desc:
        # "+ mix tasks"); the boot path now only template-seeds (no auto-grant).
        "apps/ezagent_domain_agent/lib/mix/",
        "apps/ezagent_domain_session/lib/ezagent/entity/session_template.ex",
        # PR-9a (#53): AgentTemplate relocated to the ezagent_domain_agent app.
        "apps/ezagent_domain_agent/lib/ezagent/entity/agent_template.ex",
        # Capability module references Identity.grant_cap in
        # docstrings + the session Behavior dispatches it as part of
        # the reconciler's session-create path (lift to a future
        # refactor — for now allowlisted).
        "apps/ezagent_core/lib/ezagent/capability.ex",
        "apps/ezagent_domain_session/lib/ezagent/behavior/session.ex"
      ]
    },
    %{
      id: :p8,
      desc: "MapSet.member? against cap shape outside Identity domain",
      pattern: ~r/MapSet\.member\?\([^,]*caps/,
      allowlist: [
        "apps/ezagent_domain_identity/"
      ]
    },
    %{
      id: :p9,
      desc: "hand-written cap-shape predicates (`has_admin_cap?` etc.)",
      pattern: ~r/\b(?:has_admin_cap\?|is_admin_cap\?|admin_cap_match)\b/,
      allowlist: [
        # P9 SPEC intent: zero hand-written predicates. The
        # `holds_admin_caps?` / `holds_workspace_admin_cap?` predicates
        # in `Behavior.Identity` are the SPEC's canonical cap-shape
        # predicates (defp-private, single-site, well-documented) —
        # different from the test-time `has_admin_cap?` shape this
        # probe targets.
      ]
    },
    %{
      id: :p10,
      desc: "ambient `caller: X, caps: Y` dispatch ctx outside the documented sites",
      pattern: ~r/caller:.*\n.*caps:/m,
      allowlist: [
        # caller+caps pattern is the normal dispatch ctx — allowed
        # everywhere ctx is constructed. The probe is a placeholder
        # for documenting expected sites; tightened in PR-CC-2c when
        # ctx.caps is removed.
        "apps/"
      ]
    },
    %{
      id: :p11,
      desc: "manual caller_workspace vs target_workspace comparison outside step 5.6",
      pattern: ~r/caller_workspace\s*==\s*target_workspace/,
      allowlist: [
        # Only the dispatch step 5.6 site should compare workspaces.
        "apps/ezagent_core/lib/ezagent/kind/runtime.ex"
      ]
    },
    %{
      id: :p12,
      desc: "macro-declared required_caps (defeats compile-time gate)",
      pattern: ~r/defmacro\s+required_caps\b|@__cap__/,
      allowlist: []
    },
    %{
      id: :p13,
      desc:
        "authz via hardcoded admin-principal equality (e.g. `caller == admin_uri()` OR the " <>
          "helper-form `same_uri?(caller, admin_uri())`) — the manage/admin decision must be a " <>
          "cap check at the dispatch chokepoint (hold the `:manage`/admin cap) or go through the " <>
          "canonical `Ezagent.Identity.admin?/1`, NOT a hand-written comparison to a fixed " <>
          "principal. A UI affordance flag must mirror the cap/`admin?`, not reimplement a " <>
          "narrower hardcoded one. The `same_uri?(_, admin_uri())` branch was added 2026-06-21 " <>
          "after the world plugin used it to evade the bare-`==` form (#154). " <>
          "Zero occurrences on main — regression-lock so caller==principal shortcuts fail.",
      pattern: ~r/==.*admin_uri\(\)|admin_uri\(\)\s*==|same_uri\?\([^)]*admin_uri\(\)/,
      allowlist: [
        # The canonical admin-definition home — these MUST compare to admin_uri:
        #   `Ezagent.Identity.admin?/1` is the single sanctioned "is this the admin?"
        #   predicate; everything else needing an admin check calls IT (or, for
        #   authz, a cap check), instead of re-hardcoding the comparison inline.
        "apps/ezagent_domain_identity/lib/ezagent/identity.ex",
        #   `Ezagent.Entity.User` owns `admin_uri/0` + the #154 genesis self-grant
        #   (`initial_caps_for_spawn`), which legitimately tests `uri == admin_uri()`.
        "apps/ezagent_domain_identity/lib/ezagent/entity/user.ex"
      ]
    }
  ]

  test "every probe finds zero unexpected occurrences (13 probes)" do
    umbrella_root = Path.expand("../../../..", __DIR__)
    all_files = Path.wildcard(Path.join(umbrella_root, "apps/*/lib/**/*.ex"))

    offenders =
      for probe <- @probes,
          path <- all_files,
          not allowed_path?(path, probe.allowlist),
          content = File.read!(path),
          Regex.match?(probe.pattern, content),
          do:
            "[#{probe.id}] #{probe.desc}\n      @ #{path}\n      pattern: #{inspect(probe.pattern)}"

    assert offenders == [],
           "G2 leakage — cap-check shape detected outside the dispatch chokepoint:\n\n" <>
             Enum.join(offenders, "\n\n") <>
             "\n\nSee SPEC docs/superpowers/specs/2026-05-25-caps-cleanup-v1-r4-impl.md §6."
  end

  defp allowed_path?(path, allowlist) do
    Enum.any?(allowlist, fn allowed -> String.contains?(path, allowed) end)
  end
end
