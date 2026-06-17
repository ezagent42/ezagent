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
    test "Catalog returns the expected 16 principals" do
      uris = Ezagent.SystemPrincipal.Catalog.uris()

      assert length(uris) == 16,
             "SPEC §4.1 declares 16 system principals; Catalog has #{length(uris)}: " <>
               inspect(uris)

      expected = [
        "system://bootstrap",
        "system://boot-reconciler",
        "system://adapter-install",
        "system://chat-router",
        "system://chat-reply",
        "system://worker-publish",
        "system://template-materialize",
        "system://orchestrator-tools",
        "system://session-internal",
        "system://agent-internal",
        "system://workspace-loader",
        "system://mix-task",
        "system://feishu-binding-policy",
        "system://lv-anon-mount",
        # #17 cascade PR-0 — credential-materializer (empty-cap audit identity).
        "system://credential-materializer",
        # T1A.1 — turn-adapter dispatches turn lifecycle actions on customer-service Sessions.
        "system://turn-adapter",
        # #51 §3.4 — socialware GC sweeper (Session :leave only).
        # NOTE: #51 §4.1 anon public-view access does NOT add a principal —
        # the anon holds its own narrow join cap (Decision #154).
        "system://socialware-gc"
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
      # Pathology-B follow-up to PR-CC-2-v2: chat-router/chat-reply are
      # in the wildcard-exempt allowlist now (open-plugin fan-out
      # structural — see catalog.ex moduledoc +
      # no_wildcard_system_principals_test.exs). Pick
      # `system://workspace-loader` for the narrow-catalog assertion —
      # a single-Behavior principal that legitimately should NOT hold
      # a wildcard.
      caps = Ezagent.SystemPrincipal.caps("system://workspace-loader")
      assert %MapSet{} = caps
      assert MapSet.size(caps) >= 1

      refute Enum.any?(caps, fn cap ->
               cap.kind == :any and cap.behavior == :any and
                 cap.instance == :any and cap.workspace_uri == :any
             end),
             "narrow-catalog principal must not carry a wildcard cap"
    end

    test "caps/1 returns empty MapSet for system://lv-anon-mount" do
      assert Ezagent.SystemPrincipal.caps("system://lv-anon-mount") == MapSet.new(),
             "anonymous LV mount must NOT carry ambient authority per SPEC §4.4"
    end

    test "caps/1 raises on non-system URI" do
      assert_raise ArgumentError, ~r/expects a system URI/, fn ->
        Ezagent.SystemPrincipal.caps("entity://system/user/admin")
      end
    end

    test "uri/1 returns a parsed URI for a registered service" do
      uri = Ezagent.SystemPrincipal.uri("boot-reconciler")
      assert %URI{scheme: "system"} = uri
      assert URI.to_string(uri) == "system://boot-reconciler"
    end

    test "uri/1 raises on uncataloged service name" do
      assert_raise ArgumentError, ~r/not in Ezagent\.SystemPrincipal\.Catalog/, fn ->
        Ezagent.SystemPrincipal.uri("uncataloged-principal")
      end
    end
  end
end
