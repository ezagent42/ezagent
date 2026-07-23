defmodule EzagentCore.Invariants.UriCanonicalizationInvariantTest do
  @moduledoc """
  SPEC 2026-05-27-uri-canonicalization §5 — merge gate per
  `feedback_completion_requires_invariant_test`. Catches a future
  contributor reintroducing a boundary call to stdlib
  `URI.parse/1`, `URI.new!/1`, or `URI.new/1` for an Ezagent-scheme
  URI.

  ## What the invariants enforce

  1. §5.1 — no stdlib `URI.parse/1` in `apps/*/lib/**/*.ex` (outside the
     canonical-module allowlist).
  2. §5.2 — no stdlib `URI.new!/1` outside the §3.5 compile-time
     module-attribute carve-out.
  3. §5.2.1 — no stdlib `URI.new/1` (non-bang) outside the §3.7 dual-
     fallback allowlist (`Ezagent.URI`, `Ezagent.Ecto.URI`).
  4. §5.3 — canonical URI round-trip property.
  5. §5.4 — admin URI parity (the Bug-2 regression surface).
  6. §5.5 — snapshot `canonicalize_uris/1` covers every required shape.
  7. §5.5 r3 adversarial — the same-line `URI.new(s); URI.new!(t)` mix
     is not a false negative under the §5.2.1 regex.

  ## URI hardening 2026-05-30 — query-target carve-out CLOSED

  > "address silent errors are unacceptable" — Allen 2026-05-30.

  SPEC §3.4 previously CARVED OUT the query-target idiom
  `URI.new!("\#{URI.to_string(uri)}?action=b.a")` — stdlib `URI.new!/1`
  was permitted when the line also contained `?action=`. That carve-out
  was a real silent-error hole: stdlib `URI.new!/1` yields the right
  `authority: nil` struct BUT bypasses the SchemeRegistry + 3-segment
  validation, so a typo'd scheme or malformed base passed silently. The
  carve-out is now CLOSED — those ~28 sites migrated to
  `Ezagent.URI.with_action/3`, which re-parses the assembled string
  through the canonical chokepoint (full validation). The §5.2 test no
  longer exempts `?action=` lines.

  Suppression: any line ending with `# uri-canonical-allow: <reason>`
  is exempt. This is the escape hatch for genuine structural
  derivations (e.g. `URI.new!("workspace://" <> validated_name)` in
  `Ezagent.Capability.workspace_of/1` — see SPEC §3.6).
  """
  use ExUnit.Case, async: true

  # #52 Mode-A: cross-tier suite — references sibling-app modules; resolves
  # only in the umbrella. Excluded standalone (`cd apps/ezagent_core && mix test`).
  @moduletag :umbrella_only

  @uri_new_allowlist [
    "apps/ezagent_core/lib/ezagent/uri.ex",
    "apps/ezagent_core/lib/ezagent/ecto/uri_type.ex"
  ]

  @uri_parse_allowlist [
    "apps/ezagent_core/lib/ezagent/uri.ex",
    # cc_orchestrator_seed.ex `swap_ws_path/2` parses a ws(s):// NETWORK URL
    # (orchestrator MCP mount), not an Ezagent-scheme URI. The inline
    # `# uri-canonical-allow` marker is NOT format-stable across Elixir patch
    # versions (some formatters hoist end-of-line comments above the code
    # line), so the suppression lives here instead of inline.
    "apps/ezagent_plugin_cc/lib/ezagent/orchestrator/cc_orchestrator_seed.ex"
  ]

  @lib_glob "apps/*/lib/**/*.ex"

  defp apps_root do
    out =
      case System.cmd("git", ["rev-parse", "--show-toplevel"], stderr_to_stdout: false) do
        {top, 0} ->
          top

        _ ->
          # No .git inside the release image (#21 docker) — resolve the
          # umbrella root from cwd (umbrella root or the app under test).
          cwd = File.cwd!()
          if File.dir?(Path.join(cwd, "apps")), do: cwd, else: Path.expand("../..", cwd)
      end

    String.trim(out)
  end

  defp lib_files do
    apps_root()
    |> Path.join(@lib_glob)
    |> Path.wildcard()
  end

  defp relative(path) do
    Path.relative_to(path, apps_root())
  end

  # ---------------------------------------------------------------------
  # §5.1 — no stdlib URI.parse/1 in production lib/

  test "no stdlib URI.parse/1 in apps/*/lib/**/*.ex (outside the canonical-module allowlist)" do
    violations =
      for path <- lib_files(),
          relative(path) not in @uri_parse_allowlist,
          {line, lineno, prev} <- enumerate_with_prev(path),
          # #23 — negative lookbehind for word-char OR DOT so a module-qualified
          # `Ezagent.URI.parse(` (the canonical non-raising constructor, uri.ex:242) is
          # NOT flagged — only bare stdlib `URI.parse(`. Mirrors the §5.2 URI.new! regex.
          # codex P3: ALSO catch the fully-qualified stdlib `Elixir.URI.parse(` (the bare
          # lookbehind would skip it because of the leading `.`); it is never canonical.
          Regex.match?(~r/(?<![\w.])URI\.parse\(/, line) or
            Regex.match?(~r/(?<![\w.])Elixir\.URI\.parse\(/, line),
          not suppressed_by_adjacent_uri_allow_comment?(line, prev),
          not in_comment?(line) do
        {relative(path), lineno, String.trim(line)}
      end

    assert violations == [],
           """
           Found #{length(violations)} use(s) of stdlib URI.parse/1 in production lib/.
           Use `Ezagent.URI.new!/1` instead for Ezagent-scheme URIs
           (SPEC 2026-05-27-uri-canonicalization §3). If this is a
           legitimate structural derivation, append a comment:
               # uri-canonical-allow: <reason>
           on the same line. Violations:
           #{format(violations)}
           """
  end

  # ---------------------------------------------------------------------
  # §5.2 — no stdlib URI.new!/1 outside the §3.5 module-attr carve-out.
  #
  # URI hardening 2026-05-30: the §3.4 query-target carve-out
  # (`URI.new!("...?action=...")`) is CLOSED — those sites migrated to
  # `Ezagent.URI.with_action/3` (routes through the validating chokepoint).
  # stdlib `URI.new!/1` with `?action=` is now a violation.

  test "no stdlib URI.new!/1 in apps outside §3.5 module-attr carve-out (query-target carve-out CLOSED)" do
    violations =
      for path <- lib_files(),
          relative(path) not in @uri_parse_allowlist,
          {line, lineno, prev} <- enumerate_with_prev(path),
          # Negative lookbehind `(?<![\w.])` — match the BARE stdlib
          # `URI.new!(` only, NOT a module-qualified `Ezagent.URI.new!(`
          # (the canonical chokepoint, formerly `Ezagent.URI.parse!/1`,
          # renamed 2026-05-29). Without this anchor every one of the
          # ~400 renamed call sites would false-positive as a stdlib
          # violation.
          # codex P3 (parity with §5.1): bare stdlib `URI.new!(` OR the fully-qualified
          # `Elixir.URI.new!(`; module-qualified `Ezagent.URI.new!(` stays excluded.
          Regex.match?(~r/(?<![\w.])URI\.new!\(/, line) or
            Regex.match?(~r/(?<![\w.])Elixir\.URI\.new!\(/, line),
          not is_module_attribute?(line),
          not suppressed_by_adjacent_uri_allow_comment?(line, prev),
          not in_comment?(line) do
        {relative(path), lineno, String.trim(line)}
      end

    assert violations == [],
           """
           Found #{length(violations)} use(s) of stdlib URI.new!/1 outside the
           §3.5 compile-time module-attribute carve-out.

           For a plain string: use `Ezagent.URI.new!/1`.
           For the `?action=` query-target idiom
           (`URI.new!("\#{URI.to_string(uri)}?action=b.a")`): use
           `Ezagent.URI.with_action(uri, :b, :a)` — it routes through the
           validating chokepoint instead of bypassing SchemeRegistry +
           shape validation (the closed §3.4 carve-out).
           If this is a legitimate structural derivation (§3.6), append:
               # uri-canonical-allow: <reason>
           Violations:
           #{format(violations)}
           """
  end

  # ---------------------------------------------------------------------
  # §5.2.1 — no stdlib URI.new/1 (non-bang) outside the external-fallback
  # allowlist. PCRE negative lookahead `(?!!)` rejects `URI.new!(`.

  test "no stdlib URI.new/1 in apps outside the external-URI fallback allowlist" do
    violations =
      for path <- lib_files(),
          relative(path) not in @uri_new_allowlist,
          {line, lineno, prev} <- enumerate_with_prev(path),
          matches_uri_new_no_bang?(line),
          not suppressed_by_adjacent_uri_allow_comment?(line, prev),
          not in_comment?(line) do
        {relative(path), lineno, String.trim(line)}
      end

    assert violations == [],
           """
           Found #{length(violations)} use(s) of stdlib URI.new/1 outside
           the SPEC §3.7 dual-fallback allowlist (Ezagent.URI,
           Ezagent.Ecto.URI). Use `Ezagent.URI.new!/1` (wrapped in
           try/rescue if you need to keep a `{:error, _}` contract for
           the boundary). Violations:
           #{format(violations)}
           """
  end

  # ---------------------------------------------------------------------
  # §5.2.2 (codex r1 CRIT closure) — capture / apply / alias bypasses

  test "no stdlib URI parser bypasses via &URI.parse/1, apply(URI, ...), or alias URI" do
    # Codex r1 CRIT: pre-fix the codebase had `Enum.map(&URI.parse/1)` in
    # `external_mirror/binding_row.ex:236` + `boot_reconciler.ex:131`,
    # both bypassing the regexes in §5.1 / §5.2 / §5.2.1. This
    # invariant catches every documented bypass shape:
    #
    #   - Capture syntax:  `&URI.parse/1`, `&URI.new/1`, `&URI.new!/1`
    #   - Erlang-style apply: `apply(URI, :parse, [_])`, `Kernel.apply(URI, ...)`
    #   - Module alias: `alias URI, as: Foo`
    #
    # Suppression via `# uri-canonical-allow` still applies.

    capture_re = ~r/&URI\.(parse|new!?)\//
    apply_re = ~r/(?:Kernel\.)?apply\(\s*URI\s*,\s*:(parse|new!?)\s*,/
    alias_re = ~r/^\s*alias\s+URI\b/

    violations =
      for path <- lib_files(),
          relative(path) not in @uri_parse_allowlist,
          relative(path) not in @uri_new_allowlist,
          {line, lineno, prev} <- enumerate_with_prev(path),
          Regex.match?(capture_re, line) or
            Regex.match?(apply_re, line) or
            Regex.match?(alias_re, line),
          not suppressed_by_adjacent_uri_allow_comment?(line, prev),
          not in_comment?(line) do
        {relative(path), lineno, String.trim(line)}
      end

    assert violations == [],
           """
           Found #{length(violations)} bypass(es) of the URI canonical chokepoint.
           Stdlib URI cannot be referenced via capture syntax (`&URI.parse/1`),
           Erlang-style apply (`apply(URI, :parse, [_])`), or module alias
           (`alias URI, as: Foo`). Use `Ezagent.URI.new!/1` (or the
           `&Ezagent.URI.new!/1` capture). If this is a legitimate
           structural derivation, append `# uri-canonical-allow: <reason>`
           on the same line. Violations:
           #{format(violations)}
           """
  end

  # ---------------------------------------------------------------------
  # §5.3 — canonical round-trip property

  test "canonical URI round-trips through to_string/parse! unchanged" do
    cases = [
      "entity://system/user/admin",
      "entity://team-alpha/agent/cc_demo",
      "session://system/default/main",
      "session://template-x/team-alpha/main?action=session.send",
      "template://system/agent/cc-orchestrator",
      "template://team-alpha/session/code@abc123",
      "resource://team-alpha/uploads/file-abc",
      "workspace://team-alpha",
      "workspace://system",
      "system://bootstrap/default",
      "system://routing/default"
    ]

    for s <- cases do
      a = Ezagent.URI.new!(s)
      b = Ezagent.URI.new!(URI.to_string(a))
      assert a == b, "round-trip diverged for #{s}"
      assert a.authority == nil, "expected authority:nil for #{s}, got #{inspect(a.authority)}"
      assert URI.to_string(a) == s, "to_string non-idempotent for #{s}"
    end
  end

  # ---------------------------------------------------------------------
  # §5.4 — Bug-2 parity (admin URI any-which-way)

  test "admin_uri produced any-which-way is canonical-equal" do
    from_constant = Ezagent.Entity.User.admin_uri()
    from_parse = Ezagent.URI.new!("entity://system/user/admin")
    {:ok, from_string_via_ecto} = Ezagent.Ecto.URI.load("entity://system/user/admin")

    assert from_constant == from_parse,
           "admin_uri constant != parse!/1 — would resurrect Bug 2"

    assert from_constant == from_string_via_ecto,
           "admin_uri constant != Ecto load result — would resurrect Bug 2"

    assert from_constant.authority == nil,
           "admin_uri authority is not nil (canonical-form requirement, RFC 3986)"
  end

  # ---------------------------------------------------------------------
  # §5.5 — snapshot canonicalize_uris/1 covers every required shape

  defmodule MyBinding do
    @moduledoc false
    defstruct [:uri, :meta]
  end

  test "snapshot canonicalize_uris/1 covers every required shape" do
    # parse_legacy/1 mimics the pre-migration `URI.parse/1` shape so we
    # can prove the walker rewrites all of them. We have to BYPASS the
    # invariant grep here — the test must construct non-canonical
    # forms to verify they are rewritten. This is the ONLY production
    # site where the legacy form is allowed to appear, and the
    # `# uri-canonical-allow` suppression marks the intent.
    parse_legacy = fn s ->
      # uri-canonical-allow: SPEC §5.5 adversarial fixture
      apply(URI, :parse, [s])
    end

    pre_migration_state = %{
      session: %{
        owner: parse_legacy.("entity://system/user/admin"),
        members: [parse_legacy.("entity://team-alpha/user/alice")],
        deep: %{nested: %{list: [parse_legacy.("entity://team-alpha/user/bob")]}},
        # URI as map KEY.
        per_member: %{parse_legacy.("entity://team-alpha/user/carol") => :online},
        # Tuple element.
        last_event: {:joined, parse_legacy.("entity://team-alpha/user/dave"), 1_700_000_000},
        # Custom struct holding URI.
        binding: %MyBinding{uri: parse_legacy.("entity://team-alpha/user/eve"), meta: %{}}
      }
    }

    binary = :erlang.term_to_binary(pre_migration_state)
    decoded = :erlang.binary_to_term(binary, [:safe])
    canonicalized = Ezagent.Kind.Snapshot.canonicalize_uris(decoded)

    # Map value at top level
    assert canonicalized.session.owner.authority == nil
    # List element
    assert hd(canonicalized.session.members).authority == nil
    # Deep nesting (Map → Map → List → URI)
    assert hd(canonicalized.session.deep.nested.list).authority == nil
    # Tuple element
    {tag, dave_uri, ts} = canonicalized.session.last_event
    assert tag == :joined and ts == 1_700_000_000
    assert dave_uri.authority == nil

    # Map KEY was walked
    [{carol_uri, status}] = Enum.to_list(canonicalized.session.per_member)
    assert carol_uri.authority == nil and status == :online

    # Custom struct shape preserved AND URI canonical
    assert canonicalized.session.binding.__struct__ == MyBinding
    assert canonicalized.session.binding.uri.authority == nil

    # Equality against parse!/1 result holds
    assert canonicalized.session.owner == Ezagent.URI.new!("entity://system/user/admin")
  end

  # ---------------------------------------------------------------------
  # Task #111 — canonicalize as a MAP KEY survives a snapshot round-trip
  #
  # The session-membership-survives-restart bug: a member `%URI{}` is a
  # KEY in the `:members` slice map. A caller holds a canonical
  # (`parse!/1`, authority:nil) member URI; the slice is snapshotted,
  # reloaded, and re-walked by `canonicalize_uris/1`. If the round-trip
  # were not struct-stable, the reloaded key would not `==` the held URI
  # and `Map.has_key?/2` would miss even though the strings are equal.
  #
  # This pins BOTH invariants the task requires:
  #   (1) idempotence — canonicalize(u) == canonicalize(canonicalize(u))
  #   (2) round-trip struct-equality as a map key — a URI built by the
  #       sanctioned path is `==` to the same URI after a snapshot
  #       round-trip, so `Map.has_key?/2` succeeds.

  test "canonical URI is map-key-stable across a canonicalize_uris/1 round-trip (Task #111)" do
    cases = [
      "entity://team-alpha/user/m-1",
      "entity://team-alpha/agent/cc_demo",
      "session://team-alpha/default/main",
      "session://template-x/team-alpha/main",
      "workspace://team-alpha",
      "system://routing/default"
    ]

    for s <- cases do
      held = Ezagent.URI.new!(s)

      # (1) Idempotence: canonicalize is a fixed point.
      assert Ezagent.Kind.Snapshot.canonicalize_uris(held) ==
               Ezagent.Kind.Snapshot.canonicalize_uris(
                 Ezagent.Kind.Snapshot.canonicalize_uris(held)
               ),
             "canonicalize_uris/1 not idempotent for #{s}"

      # (2) Round-trip struct-equality AS A MAP KEY through the real
      #     snapshot serialization path (term_to_binary → binary_to_term →
      #     canonicalize_uris), then prove `Map.has_key?/2` succeeds with
      #     the originally-held URI.
      members = %{held => %{online: true}}

      reloaded =
        members
        |> :erlang.term_to_binary()
        |> :erlang.binary_to_term([:safe])
        |> Ezagent.Kind.Snapshot.canonicalize_uris()

      [{reloaded_key, _}] = Enum.to_list(reloaded)

      assert reloaded_key == held,
             "reloaded member key not struct-equal to held URI for #{s} — " <>
               "Map.has_key?/2 would miss after restart"

      assert reloaded_key.authority == nil,
             "reloaded key authority not nil for #{s}"

      assert Map.has_key?(reloaded, held),
             "Map.has_key?/2 missed the originally-held URI key for #{s}"
    end
  end

  test "a stdlib-URI.parse-built (authority-bearing) key is rescued to canonical by the reload walker (Task #111)" do
    # The exact bug shape: a NON-canonical (authority:"user") URI got
    # into a snapshot (pre-migration, or a fixture built the wrong way).
    # The reload walker must rewrite it so it matches the canonical
    # form a current caller holds.
    # uri-canonical-allow: Task #111 adversarial fixture
    legacy_key = apply(URI, :parse, ["entity://team-alpha/user/m-1"])
    refute legacy_key.authority == nil, "fixture precondition: legacy key carries authority"

    held = Ezagent.URI.new!("entity://team-alpha/user/m-1")
    refute legacy_key == held, "fixture precondition: legacy and canonical structs differ"

    reloaded =
      %{legacy_key => %{online: true}}
      |> :erlang.term_to_binary()
      |> :erlang.binary_to_term([:safe])
      |> Ezagent.Kind.Snapshot.canonicalize_uris()

    assert Map.has_key?(reloaded, held),
           "the reload walker did not canonicalize a legacy authority-bearing key — " <>
             "Map.has_key?/2 with the canonical URI missed"
  end

  # ---------------------------------------------------------------------
  # §5.5 r3 adversarial — the same-line URI.new + URI.new! mix must be
  # caught by §5.2.1's regex. r4 fix uses PCRE negative lookahead.

  test "URI.new/1 invariant catches same-line URI.new + URI.new! mix" do
    assert matches_uri_new_no_bang?("foo = URI.new(s)")
    refute matches_uri_new_no_bang?("foo = URI.new!(s)")
    assert matches_uri_new_no_bang?("foo = URI.new(s); bar = URI.new!(t)")
    assert matches_uri_new_no_bang?("foo = URI.new!(s); bar = URI.new(t)")
    refute matches_uri_new_no_bang?("foo = URI.new!(s); bar = URI.new!(t)")
  end

  # ---------------------------------------------------------------------
  # helpers (kept private to the test module)

  # Returns {line, lineno, prev_line} triples. prev_line is nil for the first
  # line; otherwise it is the line immediately before the current one.
  # The formatter moves end-of-line `# uri-canonical-allow:` comments to the
  # preceding line — this enumeration lets the suppression check look at both.
  defp enumerate_with_prev(path) do
    lines = path |> File.read!() |> String.split("\n")
    prev_lines = [nil | Enum.drop(lines, -1)]

    lines
    |> Enum.with_index(1)
    |> Enum.zip(prev_lines)
    |> Enum.map(fn {{line, lineno}, prev} -> {line, lineno, prev} end)
  end

  # True when a `# uri-canonical-allow:` comment sits on the current line
  # (legacy same-line suppression) or on the immediately preceding line
  # (formatter-displaced suppression — the formatter hoists end-of-line
  # comments above the code line).
  defp suppressed_by_adjacent_uri_allow_comment?(line, prev) do
    String.contains?(line, "# uri-canonical-allow") or
      (prev != nil and String.contains?(prev, "# uri-canonical-allow:"))
  end

  defp matches_uri_new_no_bang?(line) do
    # PCRE negative lookahead — match `URI.new(` where `new` is NOT
    # immediately followed by `!`. SPEC §5.2.1 r4 fix.
    Regex.match?(~r/\bURI\.new(?!!)\(/, line)
  end

  defp is_module_attribute?(line),
    do: Regex.match?(~r/^\s*@\w+\s+URI\.new!\(/, line)

  defp in_comment?(line), do: Regex.match?(~r/^\s*#/, line)

  defp format(violations) do
    violations
    |> Enum.map(fn {path, lineno, line} -> "  #{path}:#{lineno}: #{line}" end)
    |> Enum.join("\n")
  end

  # ---------------------------------------------------------------------
  # Mutation regression — github_adapter.ex URI.parse call-site gate

  @github_adapter_rel "apps/ezagent_plugin_github/lib/ezagent_plugin_github/github_adapter.ex"

  test "github_adapter.ex is NOT whole-file exempt from URI.parse gate" do
    refute @github_adapter_rel in @uri_parse_allowlist,
           "github_adapter.ex must NOT be in @uri_parse_allowlist; " <>
             "use per-line # uri-canonical-allow: comments instead"
  end

  test "every URI.parse call in github_adapter.ex carries a # uri-canonical-allow: comment (same or preceding line)" do
    path = Path.join(apps_root(), @github_adapter_rel)
    lines = path |> File.read!() |> String.split("\n")

    uri_parse_positions =
      lines
      |> Enum.with_index(1)
      |> Enum.filter(fn {line, _lineno} ->
        Regex.match?(~r/(?<![\w.])URI\.parse\(/, line) and not in_comment?(line)
      end)

    unannotated =
      uri_parse_positions
      |> Enum.reject(fn {line, lineno} ->
        prev = if lineno > 1, do: Enum.at(lines, lineno - 2)
        suppressed_by_adjacent_uri_allow_comment?(line, prev)
      end)

    assert unannotated == [],
           """
           Every URI.parse call in github_adapter.ex must carry a
           `# uri-canonical-allow: <reason>` comment on the same line or
           the immediately preceding line (formatter-compatible).
           Unannotated call(s):
           #{format(unannotated |> Enum.map(fn {line, lineno} -> {@github_adapter_rel, lineno, String.trim(line)} end))}
           """
  end

  # Prove the gate still has teeth: a synthetic unannotated URI.parse in
  # github_adapter.ex WOULD be caught by both the regex and the suppression
  # check (mutation test). The synthetic line has no # uri-canonical-allow:
  # comment on itself or the line before it.
  test "unannotated URI.parse in github_adapter.ex is NOT suppressed by the allowlist" do
    unannotated_line = ~S|  url: URI.parse("https://example.com"),|

    assert Regex.match?(~r/(?<![\w.])URI\.parse\(/, unannotated_line),
           "synthetic test line must contain URI.parse"

    refute String.contains?(unannotated_line, "# uri-canonical-allow:"),
           "synthetic test line must NOT carry the suppression comment"

    # Neither the synthetic line nor a nil prev-line suppress it.
    refute suppressed_by_adjacent_uri_allow_comment?(unannotated_line, nil)

    # Same filter chain as the §5.1 test: the allowlist no longer includes
    # github_adapter.ex, so an unannotated URI.parse in this file would be
    # flagged.
    refute @github_adapter_rel in @uri_parse_allowlist
  end
end
