defmodule EzagentCore.Invariants.NoAdminCapsFallbackTest do
  @moduledoc """
  Architectural gate for SPEC `2026-05-25-caps-cleanup-v1.md` §4
  ("Ambient authority removal", Issue 1 / PR-CC-1).

  Two locks against regression:

  1. **No production file calls the deleted `User.admin_caps/0`.** The ambient
     escape hatch was the root pathology — every system-mediated
     dispatch elevated to wildcard admin authority instead of
     declaring its operating context. `Ezagent.SystemPrincipal` +
     `Ezagent.SystemPrincipal.Catalog` are the closed allowlist
     replacement (14 named principals + their permitted cap strings).

  2. **`Ezagent.Entity.User` does not export `admin_caps/0`.** Even
     without callers, the function being defined would allow a future
     PR to bring back the pattern without touching call-site greps.
     Deletion is the structural lock; this assertion is the
     compile-time + runtime sentinel that the deletion held.

  Per `feedback_completion_requires_invariant_test` (Allen 2026-05-05)
  — these are the two failing-when-violated tests that make PR-CC-1's
  "done" claim load-bearing.

  ## Exemptions

  - `test/support/**` is excluded from probe 1 because test helpers
    legitimately spawn ad-hoc principals; the SPEC §4.6 explicit
    carve-out. There is no test helper today that calls
    `User.admin_caps/0` (the migration handled
    `test/support/fake_cc_agent.ex` too) but the carve-out keeps the
    door open for a `SystemPrincipal.test_principal/1` style helper
    arriving in PR-CC-2.
  - Comments matching the verbatim deleted-function call would
    trigger probe 1; the migration scrubbed every production comment
    that referenced the old name verbatim. Future references must
    paraphrase ("admin caps fallback", "admin-caps shape") or the
    gate fires.
  """

  use ExUnit.Case, async: true

  describe "G1 — Ambient authority gone" do
    test "no production code calls User.admin_caps/0" do
      offenders =
        Path.wildcard("apps/*/lib/**/*.ex")
        |> Enum.reject(fn path -> String.contains?(path, "test/support") end)
        |> Enum.filter(fn path ->
          File.read!(path) =~ ~r/\bUser\.admin_caps\(\)|Ezagent\.Entity\.User\.admin_caps\(\)/
        end)

      assert offenders == [],
             "ambient authority leak — these files call User.admin_caps/0: " <>
               inspect(offenders) <>
               ". Migrate to Ezagent.SystemPrincipal.caps(\"system://<service>\") per " <>
               "SPEC 2026-05-25-caps-cleanup-v1 §4.4."
    end

    test "Ezagent.Entity.User module does not export admin_caps/0" do
      Code.ensure_loaded?(Ezagent.Entity.User)

      refute function_exported?(Ezagent.Entity.User, :admin_caps, 0),
             "Ezagent.Entity.User.admin_caps/0 must be deleted per " <>
               "SPEC 2026-05-25-caps-cleanup-v1 §4. " <>
               "Replacement: Ezagent.SystemPrincipal.caps(\"system://bootstrap\")."
    end
  end

  describe "Catalog sanity" do
    test "Catalog returns the expected 8 principals" do
      uris = Ezagent.SystemPrincipal.Catalog.uris()

      # System-principal elimination (north star): feishu-binding-policy (#824),
      # credential-materializer (#825), worker-publish (#826), then the DEAD
      # adapter-install + boot-reconciler DELETED, then agent-internal +
      # workspace-loader (2026-06-19, self-authority), then mix-task
      # (2026-06-19, operator → admin entity), then orchestrator-tools
      # (2026-06-19, DEAD caller — orchestrator runs as itself) → 7 principals
      # (shrinking toward genesis-only; see system_principal_elimination_test.exs).
      # 2026-06-20, 甲-3: chat-reply ELIMINATED → 6 principals.
      # 2026-06-20, 甲-4: chat-router ELIMINATED → 5 principals.
      # 2026-06-20, 甲-6: lv-anon-mount + socialware-gc ELIMINATED → 3 principals.
      assert length(uris) == 3,
             "expected 3 system principals; Catalog has #{length(uris)}: " <>
               inspect(uris)

      expected = [
        "system://bootstrap",
        # (chat-router ELIMINATED 2026-06-20, 甲-4 — north star; the last
        #  non-genesis wildcard holder. The Session delivery fan-out now mints a
        #  per-recipient inline `:receive` cap (member self-consent), the
        #  cross-session forward presents `session.send` granted_by the source
        #  session (same-workspace-guarded), and the agent sync_result presents
        #  an inline self-cap — none borrow this ambient wildcard.)
        # (chat-reply ELIMINATED 2026-06-20, 甲-3 — north star; the 5 agent/plugin
        #  bridge adapters now present their OWN inline narrow `session.send` cap
        #  on the concrete reply session instead of borrowing this ambient
        #  wildcard. Same play as worker-publish self-authority.)
        # (worker-publish ELIMINATED — north star; the ExternalMirrorWorker's
        #  internal dispatches now carry their own inline authorizer caps.)
        "system://template-materialize",
        # (orchestrator-tools ELIMINATED 2026-06-19 — north star; DEAD caller:
        #  the orchestrator runs its tools as itself with its own caps, and the
        #  set_legends allowlist entry was never reached in production.)
        "system://session-internal"
        # (agent-internal ELIMINATED 2026-06-19 — north star; its only authority
        #  `sandbox.write_path` is the agent writing its OWN sandbox slice →
        #  genuine self-authority, carried inline at the TemplateSpawn dispatch.)
        # (workspace-loader ELIMINATED 2026-06-19 — north star; its only authority
        #  `cap(:workspace, Workspace, :any)` is the workspace dispatching its OWN
        #  self-maintenance on its OWN slice → genuine self-authority, carried
        #  inline per-action at the Workspace facade + Loader dispatches.)
        # (mix-task ELIMINATED 2026-06-19 — north star; the operator CLI tasks
        #  now route their authority through the real `entity://system/user/admin`
        #  entity with an inline per-action admin cap, not the ambient wildcard.)
        # (lv-anon-mount ELIMINATED 2026-06-20, 甲-6 — north star; an EMPTY-caps
        #  placeholder caller for unauthenticated LV mounts; the 4 LV paths now
        #  pass `caller: nil` + empty caps directly.)
        # (credential-materializer ELIMINATED — north star; api-key materialization
        #  now runs under agent self-authority.)
        # (socialware-gc ELIMINATED 2026-06-20, 甲-6 — north star; the abandoned-anon
        #  GC reaper's `session.leave` now runs under the genesis admin entity with
        #  an inline `session.leave` cap; the anon can't self-leave.)
      ]

      assert Enum.sort(uris) == Enum.sort(expected),
             "Catalog URIs do not match SPEC §4.1 table. " <>
               "Missing: #{inspect(expected -- uris)} | Extra: #{inspect(uris -- expected)}"
    end

    test "every catalog URI resolves through caps_for!/1" do
      for uri <- Ezagent.SystemPrincipal.Catalog.uris() do
        caps = Ezagent.SystemPrincipal.Catalog.caps_for!(uri)
        assert is_list(caps), "Catalog.caps_for!(#{uri}) returned non-list: #{inspect(caps)}"
      end
    end

    test "unknown URI raises through caps_for!/1" do
      assert_raise ArgumentError, ~r/not in Ezagent\.SystemPrincipal\.Catalog/, fn ->
        Ezagent.SystemPrincipal.Catalog.caps_for!("system://not-in-catalog")
      end
    end
  end

  describe "SystemPrincipal bridge" do
    test "caps/1 returns the catalog's struct caps as a MapSet" do
      caps = Ezagent.SystemPrincipal.caps("system://bootstrap")
      assert %MapSet{} = caps
      # PR-CC-2-v2 narrowing: each catalog entry holds the cap structs
      # the principal needs. system://bootstrap remains a single
      # wildcard cap (the all-caps invariant per Decision #81).
      assert MapSet.size(caps) == 1
      [cap] = MapSet.to_list(caps)

      assert %Ezagent.Capability{kind: :any, behavior: :any, instance: :any, workspace_uri: :any} =
               cap
    end

    test "caps/1 returns narrowed struct caps for narrow-catalog principals" do
      # Pathology-B follow-up to PR-CC-2-v2: after 甲-3 (chat-reply) and 甲-4
      # (chat-router) eliminations, `system://bootstrap` is the ONLY
      # wildcard-exempt principal (see catalog.ex moduledoc +
      # no_wildcard_system_principals_test.exs). Pick
      # `system://session-internal` for the narrow-catalog assertion —
      # a single-Behavior principal that legitimately should NOT hold
      # a wildcard.
      caps = Ezagent.SystemPrincipal.caps("system://session-internal")
      assert %MapSet{} = caps
      assert MapSet.size(caps) >= 1

      refute Enum.any?(caps, fn cap ->
               cap.kind == :any and cap.behavior == :any and
                 cap.instance == :any and cap.workspace_uri == :any
             end),
             "narrow-catalog principal must not carry a wildcard cap"
    end

    # (was "caps/1 returns empty MapSet for system://lv-anon-mount" — the
    #  principal was ELIMINATED 2026-06-20, 甲-6; anonymous LV mounts now pass
    #  `caller: nil` + empty caps directly, so there is no principal to query.)

    test "caps/1 raises on non-system URI" do
      assert_raise ArgumentError, ~r/expects a system URI/, fn ->
        Ezagent.SystemPrincipal.caps("entity://system/user/admin")
      end
    end

    test "uri/1 returns a parsed URI for a registered service" do
      # (was "chat-router" — ELIMINATED 2026-06-20, 甲-4; pick any still-cataloged
      #  service so this asserts the success path, not the raise path below.)
      uri = Ezagent.SystemPrincipal.uri("template-materialize")
      assert %URI{scheme: "system"} = uri
      assert URI.to_string(uri) == "system://template-materialize"
    end

    test "uri/1 raises on uncataloged service name" do
      assert_raise ArgumentError, ~r/not in Ezagent\.SystemPrincipal\.Catalog/, fn ->
        Ezagent.SystemPrincipal.uri("uncataloged-principal")
      end
    end
  end
end
