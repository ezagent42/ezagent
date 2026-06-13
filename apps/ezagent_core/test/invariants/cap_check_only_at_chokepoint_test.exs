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
        "apps/ezagent_domain_instance_message/lib/ezagent/",
        # PR-8 (transport #53) — the orchestrator-MCP subsystem (incl.
        # `Orchestrator.Tools.Templates`, which reads `matches?` for read-only
        # tooling display, same class as mcp_server.ex in p6) relocated im → cc.
        "apps/ezagent_plugin_cc/lib/ezagent/orchestrator/",
        "apps/ezagent_plugin_liveview/lib/",
        # Mix tasks consume matches? for CLI display.
        "apps/ezagent_domain_external_mirror/lib/mix/tasks/",
        "apps/ezagent_core/lib/mix/tasks/"
      ]
    },
    %{
      id: :p4,
      desc: "cap_subjects/0 callback declaration outside Behavior contract + impls",
      pattern: ~r/def\s+cap_subjects\b/,
      allowlist: [
        "apps/ezagent_core/lib/ezagent/behavior.ex",
        "apps/ezagent_core/lib/ezagent/behavior/",
        "apps/ezagent_domain_instance_message/lib/ezagent/behavior/",
        "apps/ezagent_domain_external_mirror/lib/ezagent/behavior/",
        "apps/ezagent_domain_identity/lib/ezagent/behavior/",
        "apps/ezagent_domain_pty/lib/ezagent/behavior/",
        "apps/ezagent_domain_workspace/lib/ezagent/behavior/",
        "apps/ezagent_plugin_curl_agent/lib/ezagent/behavior/",
        "apps/ezagent_plugin_echo/lib/ezagent/behavior/",
        "apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/behavior/",
        "apps/ezagent_plugin_np/lib/ezagent/behavior/",
        # P3-2 — the socialware customer_feed `:pull` ExternalAdapter co-locates
        # its cap-only allow-cap behavior (`CustomerFeedAdapter.Allow`, declaring
        # `cap_subjects/0`) with the adapter, so the adapter owns its own bind
        # cap (plugin-isolation). A precise file allowlist (not the whole app)
        # keeps the cap shape contained.
        "apps/ezagent_domain_socialware/lib/ezagent/socialware/customer_feed_adapter.ex",
        # P4 — the chat_feed `:pull` ExternalAdapter co-locates its cap-only
        # allow-cap behavior (`ChatFeedAdapter.Allow`, declaring `cap_subjects/0`)
        # with the adapter, exactly as P3-2's customer_feed does (plugin-isolation:
        # the adapter owns its own bind cap). Precise file allowlist keeps the cap
        # shape contained.
        "apps/ezagent_domain_socialware/lib/ezagent/socialware/chat_feed_adapter.ex"
      ]
    },
    %{
      id: :p5,
      desc: "CapabilityRegistry.lookup outside dispatch + LV admin display",
      pattern: ~r/CapabilityRegistry\.(?:lookup|fetch|get)\b/,
      allowlist: [
        "apps/ezagent_core/lib/ezagent/",
        "apps/ezagent_plugin_liveview/lib/"
      ]
    },
    %{
      id: :p6,
      desc: "Identity.list_caps_for/1 outside Identity domain + LV display + tooling",
      pattern: ~r/Identity\.list_caps_for\b/,
      allowlist: [
        "apps/ezagent_domain_identity/",
        "apps/ezagent_core/lib/ezagent/kind.ex",
        "apps/ezagent_plugin_liveview/lib/",
        # Orchestrator MCP tool — read-only display of caps to LLM
        # callers (P6 docstring allows tooling).
        "apps/ezagent_plugin_cc/lib/ezagent/orchestrator/mcp_server.ex",
        # External-mirror CLI — operator-driven cap display.
        "apps/ezagent_domain_external_mirror/lib/mix/tasks/",
        # Feishu binding sender resolver — read-only inbound-binding
        # lookup (no grant/mutation, just display).
        "apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/sender_resolver.ex",
        # Session entity — chat send recipient-resolution reads
        # member caps to filter mention-gated routing.
        "apps/ezagent_domain_instance_message/lib/ezagent/entity/session.ex",
        # RFC #402 (Allen 2026-05-26) — the internal session creator
        # reads the creator's caps to skip a duplicate OrchestratorAdmin
        # :restart cap grant when an equivalent one already exists.
        # This is an idempotency-check on the create path (read-only
        # against the grantee's own caps), NOT a cap-gate decision
        # outside the dispatch chokepoint.
        "apps/ezagent_domain_instance_message/lib/ezagent_domain_instance_message/session_creator.ex",
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
        "apps/ezagent_domain_instance_message/lib/ezagent/behavior/turn.ex"
      ]
    },
    %{
      id: :p7,
      desc: "Identity.grant_cap/3 outside Identity Behavior + admin LV + mix tasks",
      pattern: ~r/Identity\.grant_cap\b/,
      allowlist: [
        "apps/ezagent_domain_identity/lib/ezagent/",
        "apps/ezagent_plugin_liveview/lib/",
        "apps/ezagent_domain_workspace/lib/mix/",
        "apps/ezagent_domain_instance_message/lib/ezagent/entity/session_template.ex",
        "apps/ezagent_domain_instance_message/lib/ezagent/entity/agent_template.ex",
        # Capability module references Identity.grant_cap in
        # docstrings + the session Behavior dispatches it as part of
        # the reconciler's session-create path (lift to a future
        # refactor — for now allowlisted).
        "apps/ezagent_core/lib/ezagent/capability.ex",
        "apps/ezagent_domain_instance_message/lib/ezagent/behavior/session.ex"
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
    }
  ]

  test "every probe finds zero unexpected occurrences (12 probes)" do
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
