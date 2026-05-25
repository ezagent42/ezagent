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
      # `substitute_wildcard_kind` IDENTIFIER REFERENCE (call OR pipe target)
      # within the `string_cap_check/5` function and the FIRST
      # `Ezagent.Kind.holds_cap?(` call.
      #
      # We anchor on the docstring (`# String-cap path (PR-CC-2b new arm).`)
      # to ensure both positions are within the same function — otherwise
      # the `def substitute_wildcard_kind/2` declaration further down the
      # file would race ahead of holds_cap?, creating a false-positive pass.
      anchor_pos = string_pos(src, "# String-cap path (PR-CC-2b new arm).")

      assert anchor_pos != nil,
             "Could not find the string_cap_check/5 docstring anchor. The " <>
               "wildcard ordering check requires this anchor to scope both " <>
               "subsequent searches to the same function."

      sub_call_pos = string_pos_from(src, "|> substitute_wildcard_kind", anchor_pos)
      holds_call_pos = string_pos_from(src, "Ezagent.Kind.holds_cap?(%{identity:", anchor_pos)

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

  # Find the first occurrence of `needle` at or after `from_pos`. Used to
  # scope ordering checks to a specific function body — the caller picks
  # an anchor string near the function head and both sub-searches start
  # there.
  defp string_pos_from(source, needle, from_pos) when is_integer(from_pos) do
    tail = binary_part(source, from_pos, byte_size(source) - from_pos)

    case :binary.match(tail, needle) do
      {pos, _len} -> from_pos + pos
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
  #
  # PR-CC-2b codex round-1 MEDIUM-2 fix: strip comment lines BEFORE the
  # contains check. A `# uses system://foo` line was previously enough to
  # satisfy P3 — that's a false positive. Comment stripping is conservative
  # (only single-line `#` comments — `@moduledoc` and other heredoc forms
  # are untouched because they live inside string literals that may
  # legitimately mention catalog URIs in docs, but the check requires
  # ALSO seeing `SystemPrincipal.ensure` in the SAME source which itself
  # would only happen at a real call site).
  defp ensure_pattern_present?(body, uri) do
    stripped = strip_comments(body)
    String.contains?(stripped, "SystemPrincipal.ensure") and String.contains?(stripped, uri)
  end

  # Remove single-line `#` comments — preserves string literals + heredocs
  # which may contain `#` characters but aren't comments.
  defp strip_comments(body) do
    body
    |> String.split("\n")
    |> Enum.map(&strip_line_comment/1)
    |> Enum.join("\n")
  end

  defp strip_line_comment(line) do
    # Conservative line-by-line `#`-comment stripper. Walks the line one
    # codepoint at a time tracking whether we're inside a string literal
    # so that a `#` inside `"..."` isn't treated as a comment. This is
    # not a full Elixir lexer (heredocs, sigils, interpolations are not
    # handled exhaustively) but it's accurate enough for the catalog
    # URI literals we care about — they only ever appear as bare strings
    # in the seeding helpers, never inside a complex literal.
    {result, _in_string} =
      line
      |> String.to_charlist()
      |> Enum.reduce_while({"", false}, fn ch, {acc, in_string?} ->
        cond do
          ch == ?# and not in_string? ->
            {:halt, {acc, in_string?}}

          ch == ?" ->
            {:cont, {acc <> <<ch>>, not in_string?}}

          true ->
            {:cont, {acc <> <<ch>>, in_string?}}
        end
      end)

    result
  end
end
