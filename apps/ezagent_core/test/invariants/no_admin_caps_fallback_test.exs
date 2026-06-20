defmodule EzagentCore.Invariants.NoAdminCapsFallbackTest do
  @moduledoc """
  Architectural gate for SPEC `2026-05-25-caps-cleanup-v1.md` §4
  ("Ambient authority removal", Issue 1 / PR-CC-1), updated for the #154
  genesis collapse (2026-06-20).

  Two locks against regression:

  1. **No production file calls the deleted `User.admin_caps/0`.** The ambient
     escape hatch was the root pathology — every system-mediated dispatch
     elevated to wildcard admin authority instead of declaring its operating
     context. The genesis authority is now the admin ENTITY's single
     self-granted wildcard, minted by `Ezagent.Capability.admin_genesis_cap/0`
     (granted_by `entity://system/user/admin`).

  2. **`Ezagent.Entity.User` does not export `admin_caps/0`.** Even without
     callers, the function being defined would allow a future PR to bring back
     the pattern without touching call-site greps. Deletion is the structural
     lock; this assertion is the compile-time + runtime sentinel.

  3. **The closed `SystemPrincipal.Catalog` is now EMPTY** (the #154 terminal
     state). The allowlist admits NO `system://` principal as an authorization
     source — `caps_for!/1` and `SystemPrincipal.caps/1`/`uri/1` raise for
     every input (including the former `system://bootstrap`, now collapsed into
     the admin entity). This is the standing guard that the machinery grants no
     ambient authority. (The empty-Catalog + genesis-traces-to-admin invariant
     is asserted in full by `system_principal_elimination_test.exs`; the
     vestigial `SystemPrincipal`/`Catalog` modules are slated for deletion in a
     follow-up cleanup.)

  Per `feedback_completion_requires_invariant_test` (Allen 2026-05-05) — these
  are the failing-when-violated tests that make the "done" claim load-bearing.

  ## Exemptions

  - `test/support/**` is excluded from probe 1 because test helpers
    legitimately spawn ad-hoc principals (SPEC §4.6 carve-out).
  - Comments matching the verbatim deleted-function call would trigger probe 1;
    future references must paraphrase ("admin caps fallback").
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
               ". Use Ezagent.Capability.admin_genesis_cap/0 (the admin-entity " <>
               "self-granted genesis wildcard) per #154."
    end

    test "Ezagent.Entity.User module does not export admin_caps/0" do
      Code.ensure_loaded?(Ezagent.Entity.User)

      refute function_exported?(Ezagent.Entity.User, :admin_caps, 0),
             "Ezagent.Entity.User.admin_caps/0 must stay deleted per " <>
               "SPEC 2026-05-25-caps-cleanup-v1 §4. " <>
               "Replacement: Ezagent.Capability.admin_genesis_cap/0."
    end
  end

  describe "Closed Catalog is EMPTY (#154 terminal state)" do
    test "Catalog has zero system principals" do
      uris = Ezagent.SystemPrincipal.Catalog.uris()

      assert uris == [],
             "the closed Catalog must be EMPTY after the genesis collapse " <>
               "(every authority traces to a real entity); Catalog has: #{inspect(uris)}"
    end

    test "caps_for!/1 raises for the former genesis principal (no longer cataloged)" do
      assert_raise ArgumentError, ~r/not in Ezagent\.SystemPrincipal\.Catalog/, fn ->
        Ezagent.SystemPrincipal.Catalog.caps_for!("system://bootstrap")
      end
    end

    test "caps_for!/1 raises for any uncataloged URI" do
      assert_raise ArgumentError, ~r/not in Ezagent\.SystemPrincipal\.Catalog/, fn ->
        Ezagent.SystemPrincipal.Catalog.caps_for!("system://not-in-catalog")
      end
    end
  end

  describe "SystemPrincipal bridge admits no principal" do
    test "caps/1 raises for the former genesis principal (Catalog empty)" do
      assert_raise ArgumentError, ~r/not in Ezagent\.SystemPrincipal\.Catalog/, fn ->
        Ezagent.SystemPrincipal.caps("system://bootstrap")
      end
    end

    test "caps/1 raises on a non-system URI" do
      assert_raise ArgumentError, ~r/expects a system URI/, fn ->
        Ezagent.SystemPrincipal.caps("entity://system/user/admin")
      end
    end

    test "uri/1 raises for any service name (Catalog empty)" do
      assert_raise ArgumentError, ~r/not in Ezagent\.SystemPrincipal\.Catalog/, fn ->
        Ezagent.SystemPrincipal.uri("bootstrap")
      end
    end
  end
end
