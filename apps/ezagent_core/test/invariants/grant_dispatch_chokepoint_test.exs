defmodule Ezagent.Invariants.GrantDispatchChokepointTest do
  @moduledoc """
  Structural invariant (GLOSSARY Decision #154, SPEC
  `docs/superpowers/specs/2026-06-17-unified-grant-chokepoint.md` §3.4):
  a capability **grant/revoke dispatch** may be constructed in EXACTLY ONE
  place — the chokepoint module `Ezagent.Identity.Grant`
  (`apps/ezagent_domain_identity/lib/ezagent/identity/grant.ex`).

  Routing every grant/revoke through one chokepoint is what makes the
  three roles (caller / authorizer / granter) explicit and forces an
  entity `granted_by` on every issued cap. A fresh hand-rolled grant site
  could silently re-introduce a non-entity granter — the `no_unowned`
  gate (#812) only catches Catalog minters, not a new dispatch site. This
  gate closes that hole.

  ## What it scans for (ratchet idiom — `no_unowned_system_principal_grant_test`
  / `undeclared_umbrella_dep_test`)

  Three dispatch-construction shapes in non-test `apps/**/*.ex`:

    1. **literal** — `action: :grant_cap` / `action: :revoke_cap` (the
       action field of a `%Cmd{}` / `%Invocation{}` / effect map).
    2. **variable** (the BLOCKER-3 evasion) — a function head/clause
       constraining the action var: `when action in [:grant_cap, …]`
       (which `member_create_session_cap_cmd/4` used pre-chokepoint to
       build a `%Cmd{action: action}` for BOTH grant and revoke).
    3. **legacy URI shape** — `with_action(_, :identity, :grant_cap)` /
       `with_action(_, :identity, :revoke_cap)` (the pre-`Cmd`
       `?action=identity.grant_cap` target builder).

  ## Teeth (none is a tautology)

    1. Every match is in the chokepoint file (allowlist).
    2. The allowlist is **shrink-only** — a compile-time constant of
       exactly ONE file. A 2nd allowlisted file fails tooth 3.
    3. `@allowlist_size` pins the allowlist to 1 (the ratchet). Adding a
       bypass site OR widening the allowlist trips a gate.

  Comments and `@moduledoc`/`@doc` heredoc prose are filtered (a doc
  reference to `identity.grant_cap` is not a dispatch construction).

  `async: true`; pure source scan (no app state).
  """
  use ExUnit.Case, async: true

  # The SOLE place a grant/revoke dispatch may be constructed.
  @chokepoint_path "apps/ezagent_domain_identity/lib/ezagent/identity/grant.ex"

  # Ratchet — the allowlist may only ever shrink (it cannot reach 0: the
  # chokepoint itself constructs the dispatch). A 2nd entry must trip this.
  @allowlist [@chokepoint_path]
  @allowlist_size 1

  # The three grant/revoke dispatch-construction shapes (§3.4).
  @patterns [
    # literal action field
    "action:[[:space:]]*:(grant|revoke)_cap",
    # variable-action guard (the BLOCKER-3 shape)
    "when action in \\[:(grant|revoke)_cap",
    # legacy ?action=identity.<grant|revoke>_cap target builder
    "with_action\\([^)]*:identity,[[:space:]]*:(grant|revoke)_cap"
  ]

  test "the allowlist is a shrink-only constant of exactly one file (the chokepoint)" do
    assert @allowlist == [@chokepoint_path]
    assert length(@allowlist) == @allowlist_size

    assert @allowlist_size == 1,
           "The grant-dispatch allowlist must stay 1 (the chokepoint). It may only shrink, " <>
             "never grow — a 2nd entry means a bypass site was allowlisted instead of migrated."
  end

  test "no grant/revoke dispatch is constructed outside Ezagent.Identity.Grant" do
    apps_root = apps_root()

    violations =
      @patterns
      |> Enum.flat_map(&grep(&1, apps_root))
      |> Enum.reject(&comment_or_docstring?/1)
      |> Enum.reject(&allowed?/1)
      |> Enum.uniq()
      |> Enum.sort()

    assert violations == [],
           """
           Grant/revoke dispatch constructed OUTSIDE the chokepoint
           (#{@chokepoint_path}):

           #{Enum.join(violations, "\n")}

           Every capability grant/revoke MUST route through
           Ezagent.Identity.Grant (SPEC 2026-06-17 §3.4, Decision #154) so the
           entity granted_by is derived + validated in ONE place. Replace the
           hand-rolled %Cmd{}/%Invocation{}/effect with the matching
           Ezagent.Identity.Grant wrapper:
             grant_cap/3 | revoke_cap/3 (imperative, Invocation)
             grant_cap_via_router/4 (imperative, Router %Cmd)
             grant_cap_effect/3 | grant_cap_returning_effect/4 |
             revoke_cap_returning_effect/4 (Behavior effects).
           """
  end

  # ── helpers ───────────────────────────────────────────────────────────

  defp grep(pattern, apps_root) do
    {output, exit_code} =
      System.cmd(
        "grep",
        ["-rEn", pattern, apps_root, "--include=*.ex"],
        stderr_to_stdout: false
      )

    # 0 = matches, 1 = clean; ≥2 = scan error → fail loud (never pass on error).
    if exit_code > 1, do: raise("grep scan failed (exit #{exit_code}) for pattern #{pattern}")

    output
    |> String.split("\n", trim: true)
    |> Enum.reject(&test_file?/1)
  end

  defp test_file?(line) do
    String.contains?(line, "/test/") or String.contains?(line, "_test.exs")
  end

  defp allowed?(line) do
    Enum.any?(@allowlist, &String.contains?(line, &1))
  end

  # A match that is a `#` comment or appears inside a `@moduledoc`/`@doc`
  # heredoc (prose reference to `identity.grant_cap`, an inline code-block
  # example) — not a real dispatch construction. Conservative: a false
  # negative only lets a real bug through (the runtime grant boundary +
  # the no_unowned gate are the backstops); a false positive would fail
  # the gate on prose.
  defp comment_or_docstring?(line) do
    case String.split(line, ":", parts: 3) do
      [_path, _lineno, body] ->
        trimmed = String.trim_leading(body)

        String.starts_with?(trimmed, "#") or
          prose_reference?(body)

      _ ->
        false
    end
  end

  # Heredoc-prose heuristic: a backtick or `→` BEFORE the match token means
  # the reference is inside doc prose, not a code construction.
  defp prose_reference?(body) do
    Enum.any?(["action:", "when action in", "with_action"], fn token ->
      case String.split(body, token, parts: 2) do
        [prefix, _suffix] -> String.contains?(prefix, "`") or String.contains?(prefix, "→")
        _ -> false
      end
    end)
  end

  defp apps_root do
    top =
      case System.cmd("git", ["rev-parse", "--show-toplevel"], stderr_to_stdout: false) do
        {out, 0} ->
          String.trim(out)

        _ ->
          cwd = File.cwd!()
          if File.dir?(Path.join(cwd, "apps")), do: cwd, else: Path.expand("../..", cwd)
      end

    Path.join(top, "apps")
  end
end
