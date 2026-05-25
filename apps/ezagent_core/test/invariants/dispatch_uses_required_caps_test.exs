defmodule Ezagent.Invariants.DispatchUsesRequiredCapsTest do
  @moduledoc """
  PR-CC-2b architectural invariant — dispatch step 5.5 is wired to the
  new caps machinery, and every Application that uses a `system://`
  principal has a corresponding `SystemPrincipal.ensure/1` call in its
  source.

  SPEC `docs/superpowers/specs/2026-05-25-caps-cleanup-v1.md` §5.3 +
  §4.3. Per `feedback_completion_requires_invariant_test`, this test
  fails if PR-CC-2b's structural goal is unmet — it is the gate on
  whether dispatch actually flipped to the string-cap path AND every
  catalog principal has a declared boot home.

  ## Probe set

  - P1: `Ezagent.Kind.Runtime` source references `Ezagent.Behavior.required_cap_for/2`
    (the entry point for reading a Behavior's per-action cap STRING)
    and `Ezagent.Kind.holds_cap?` (the cap check primitive).
  - P2: `Ezagent.Kind.Runtime` source contains the `substitute_wildcard_kind`
    helper, AND its call appears BEFORE the `holds_cap?` call so the
    needed cap's kind segment is resolved to the target Kind's
    `type_name` before matching the caller's slice.
  - P3: For each entry in `Ezagent.SystemPrincipal.Catalog`, at least
    one Application source file (excluding the Catalog module itself,
    the `SystemPrincipal` module, the runtime dispatch, and tests)
    contains a `SystemPrincipal.ensure(...)` call referencing that URI
    string.

  ## Why source-level checks

  PR-CC-2b's deliverable is structural: the dispatch path and Application
  boot order must contain the seed calls. Boot-time SQLite Sandbox racing
  makes runtime spawn assertions brittle in CI; the source-level grep is
  the architectural lock — it fails when a future PR removes the boot
  seed even if all runtime tests still pass (the regression failure mode
  this test exists to prevent).
  """
  use ExUnit.Case, async: true

  @runtime_path Path.expand(
                  "../../lib/ezagent/kind/runtime.ex",
                  __DIR__
                )

  describe "dispatch step 5.5 uses Behavior.required_caps + Kind.holds_cap?" do
    test "P1 — runtime.ex references the new primitives" do
      src = File.read!(@runtime_path)

      assert src =~ "Ezagent.Behavior.required_cap_for",
             "Expected Kind.Runtime to call Ezagent.Behavior.required_cap_for/2 — " <>
               "the entry point for reading a Behavior's per-action cap STRING " <>
               "(SPEC caps-cleanup-v1 §5.3). Dispatch step 5.5 has NOT switched " <>
               "to the new path."

      assert src =~ "Ezagent.Kind.holds_cap?",
             "Expected Kind.Runtime to call Ezagent.Kind.holds_cap? — the cap " <>
               "matcher entry point from PR-CC-2a. Dispatch step 5.5 has NOT " <>
               "switched to the new path."
    end

    test "P2 — wildcard substitution exists AND fires before holds_cap?" do
      src = File.read!(@runtime_path)

      assert src =~ "substitute_wildcard_kind",
             "Expected Kind.Runtime to define a substitute_wildcard_kind/2 helper. " <>
               "Behaviors registered on multiple Kinds (Routing, Chat:receive, " <>
               "Identity, IdentityAdmin) declare the kind segment as `*` — the " <>
               "needed cap must substitute `*` with the target Kind's type_name " <>
               "BEFORE calling holds_cap?, otherwise holders with concrete-kind " <>
               "caps cannot match the wildcard."

      # Ordering check — the substitution call must precede the holds_cap? call
      # inside the same function. We look at the lexical position of the FIRST
      # `substitute_wildcard_kind(` CALL (not the def) and the FIRST
      # `Ezagent.Kind.holds_cap?(` call.
      sub_call_pos = string_pos(src, "substitute_wildcard_kind(raw_needed")
      holds_call_pos = string_pos(src, "Ezagent.Kind.holds_cap?(%{identity:")

      assert sub_call_pos != nil,
             "Could not find the substitute_wildcard_kind/2 call site in " <>
               "Kind.Runtime — wildcard substitution must happen inside the " <>
               "dispatch step 5.5 code path."

      assert holds_call_pos != nil,
             "Could not find the Ezagent.Kind.holds_cap?/2 call site in " <>
               "Kind.Runtime — dispatch step 5.5 must call holds_cap? against " <>
               "the caller's wrapped slice."

      assert sub_call_pos < holds_call_pos,
             "Wildcard substitution at byte #{sub_call_pos} must precede the " <>
               "holds_cap? call at byte #{holds_call_pos}. Otherwise a Behavior " <>
               "declaring `*.chat.receive` cannot match a holder's concrete " <>
               "`session.chat.receive` cap."
    end
  end

  describe "every Catalog principal has a boot-time SystemPrincipal.ensure/1 call" do
    test "P3 — each catalog URI appears in at least one Application source" do
      catalog_uris = Ezagent.SystemPrincipal.Catalog.uris()

      # Excluded files — these define / document the Catalog or are tests; they
      # MENTION the URIs without seeding them.
      excluded = [
        "apps/ezagent_core/lib/ezagent/system_principal.ex",
        "apps/ezagent_core/lib/ezagent/system_principal/catalog.ex",
        "apps/ezagent_core/lib/ezagent/kind/runtime.ex",
        "apps/ezagent_core/lib/ezagent/kind.ex"
      ]

      app_sources = collect_application_sources(excluded)

      missing =
        Enum.reject(catalog_uris, fn uri ->
          Enum.any?(app_sources, fn {_path, body} ->
            ensure_pattern_present?(body, uri)
          end)
        end)

      assert missing == [],
             "These Catalog principals have NO `SystemPrincipal.ensure/1` " <>
               "call in any Application source (PR-CC-2b deliverable 2):\n\n" <>
               Enum.map_join(missing, "\n", &("  - " <> &1)) <>
               "\n\nEach principal in the catalog (caps-cleanup-v1 §4.1) " <>
               "must be seeded by the Application matching its Operating context."
    end
  end

  # --- helpers --------------------------------------------------------------

  defp string_pos(source, needle) do
    case :binary.match(source, needle) do
      {pos, _len} -> pos
      :nomatch -> nil
    end
  end

  # Walk apps/*/lib for any file declaring `defmodule .*Application` AND read
  # its body. Returns `[{path, body}, ...]`.
  defp collect_application_sources(excluded) do
    apps_dir = Path.expand("../../../..", __DIR__)
    excluded_abs = MapSet.new(Enum.map(excluded, &Path.expand(&1, apps_dir)))

    Path.wildcard(Path.join(apps_dir, "apps/*/lib/**/application.ex"))
    |> Enum.reject(&MapSet.member?(excluded_abs, &1))
    |> Enum.map(fn path -> {path, File.read!(path)} end)
  end

  # Does the source contain a `SystemPrincipal.ensure(...)` call referencing
  # this URI? We accept either a literal string (`"system://foo"`) inline in
  # the call OR a list-of-strings pattern where the URI appears in a literal
  # inside a `seed_*_system_principals/0` helper.
  defp ensure_pattern_present?(body, uri) do
    String.contains?(body, "SystemPrincipal.ensure") and String.contains?(body, uri)
  end
end
