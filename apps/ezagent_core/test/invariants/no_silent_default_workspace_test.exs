defmodule Ezagent.Invariants.NoSilentDefaultWorkspaceTest do
  @moduledoc """
  SPEC #324 rev 3 — runtime workspace fallback gate (Allen 2026-05-26).

  Companion to `no_default_workspace_test.exs`. While that test catches
  the *literal* form (`workspace://default`, `:workspace, "system"`,
  `Map.get(_, :workspace, "...")`), this test catches the **runtime
  fallback** forms that run at request-time:

      # same-line `||` fallback
      workspace_name = workspace_uri.host || "default"

      # multiline `||` fallback (line break after the operator)
      workspace_name =
        workspace_uri.host ||
          "default"

      # case-expression workspace derivation with a string-literal default
      workspace_name =
        case Capability.workspace_of(uri) do
          %URI{host: ws} when is_binary(ws) -> ws
          _ -> "default"
        end

      # single-clause function returning a literal as workspace default
      defp workspace_name_from_caller(_), do: "system"

  Per Allen 2026-05-26 09:31 (verbatim): "如果没有提供workspace name,
  应该直接crash。现在已经没有了默认workspace这个概念" — there is no
  default workspace concept; missing workspace MUST raise, not silently
  pick one. The 14-site sweep that landed alongside this test deleted
  every such fallback; the gate keeps it that way.

  ## What is banned (4 sub-patterns)

  1. `<ident-containing-workspace>.host || "<literal>"` on a single line.
  2. `<ident-containing-workspace>.host ||\n   "<literal>"` (multiline).
  3. `case <Capability|Workspace>.workspace_of(...) do ... _ -> "<lit>" end`
     — catch-all returning a string-literal workspace.
  4. `defp <name-containing-workspace>(_), do: "<literal>"` — single-clause
     function returning a literal as workspace fallback.

  ## What is OK

  - Comment prose using the forbidden text (skipped: leading `#` lines).
  - Non-workspace `host` fields (`some_uri.host || "..."` where the var
    is not workspace-shaped).
  - `workspace_uri.host || raise ArgumentError, "..."` — the canonical
    let-it-crash rewrite.
  - `case ... _ -> raise ArgumentError, "..."` — explicit raise.
  - `defp workspace_xyz(_), do: raise ArgumentError, "..."` — explicit raise.
  - This test itself (whitelisted below).

  ## Why scoped to `apps/*/lib/` only

  Same scoping rationale as `no_default_workspace_test.exs`: production
  lib is the structural contract; test fixtures may exercise legacy
  shapes as opt-in regression-locking.

  ## Why per-file whole-source regex instead of per-line

  The multiline `||` form (P2) and the case-expression form (P3) span
  multiple lines. A per-line scan misses them, as codex r1 (PR #362)
  surfaced. We strip comments via a line filter, then concat back to
  one string and `Regex.scan/2` with multi-line patterns.
  """

  use ExUnit.Case, async: true

  # P1 + P2: `<workspace_ident>.host || "<literal>"` — same-line OR
  # multiline (with `\s+` covering any whitespace after `||`). The
  # `[^.\s]*` after `workspace` blocks `.`-chains breaking out of the
  # workspace ident (e.g. `workspace_uri.host` matches, but
  # `other_workspace_helper.host` doesn't because the `_helper.host`
  # access isn't on a workspace-shaped value). `(?i)` makes "workspace"
  # case-insensitive; `(?s)` makes `.` cross newlines for the multiline
  # variant.
  @host_or_literal_pattern ~r/(?si)\bworkspace[a-z0-9_]*\.host\s*\|\|\s*"[^"]+"/

  # P3: `case ... do ... _ -> "default"|"system" end` where the case
  # head mentions `workspace_of` or `.host` — i.e. case-expression
  # workspace derivation with a banned-literal catch-all. `(?s)` makes
  # `.` cross newlines; `\bworkspace_of\b|\.host\b` localizes the case
  # head to workspace derivation; the catch-all `_ ->\s*"default"|"system"`
  # is the offense. Like P4, restricted to the two banned values to
  # avoid false-positives on UI case-expressions returning display
  # strings.
  @case_workspace_literal_pattern ~r/(?si)case\s+[^\n]*?(?:workspace_of\b|\.host\b)[^\n]*?do\s+.*?_\s*->\s*"(?:default|system)"/

  # P4: `defp <workspace_*>(_), do: "default"|"system"` — a single-
  # clause catch-all function whose name contains "workspace" AND
  # which returns one of the two banned workspace literals (`"default"`
  # or `"system"`). Both conditions together:
  #   * function-name contains "workspace" → narrows to workspace-shaped
  #     helpers; UI badge helpers like `defp type_badge_variant(_), do:
  #     "default"` (returns CSS class name) are excluded.
  #   * literal is one of `"default"|"system"` → narrows to actual
  #     workspace-default values; UI display helpers like
  #     `defp workspace_item_name(_), do: "—"` (returns em-dash label)
  #     are excluded.
  # Both conditions are necessary; either alone is too broad.
  @defp_workspace_literal_pattern ~r/(?i)defp\s+[a-z_]*workspace[a-z_]*\([^)]*\)[^,]*,\s*do:\s*"(?:default|system)"/

  @forbidden_patterns [
    {@host_or_literal_pattern, "workspace_uri.host || \"<literal>\" — must raise instead"},
    {@case_workspace_literal_pattern,
     "case workspace_of(...) / .host do ... _ -> \"<literal>\" — must raise instead"},
    {@defp_workspace_literal_pattern,
     "defp <workspace>(_), do: \"<literal>\" — single-clause catch-all returning string default; must raise instead"}
  ]

  @whitelist [
    "apps/ezagent_core/test/invariants/no_silent_default_workspace_test.exs",
    "test/invariants/no_silent_default_workspace_test.exs"
  ]

  test "no production lib has any silent workspace fallback (4 sub-patterns)" do
    offenders =
      lib_files()
      |> Enum.flat_map(fn path ->
        # Strip comment lines so prose discussing the banned shape
        # doesn't false-positive. Then re-join so multi-line patterns
        # still match across line breaks.
        source =
          path
          |> File.read!()
          |> String.split("\n")
          |> Enum.reject(fn line -> String.starts_with?(String.trim_leading(line), "#") end)
          |> Enum.join("\n")

        Enum.flat_map(@forbidden_patterns, fn {regex, label} ->
          case Regex.scan(regex, source) do
            [] ->
              []

            matches ->
              Enum.map(matches, fn [m | _] ->
                snippet = m |> String.replace(~r/\s+/, " ") |> String.slice(0, 200)
                "#{path}: [#{label}] #{snippet}"
              end)
          end
        end)
      end)

    assert offenders == [],
           "Found silent workspace fallbacks (SPEC #324 rev 3 forbids):\n\n" <>
             Enum.join(offenders, "\n\n") <>
             "\n\nPer Allen 2026-05-26: no default workspace concept exists. Rewrite each " <>
             "site to `raise ArgumentError, \"...\"` instead of returning a string literal. " <>
             "Canonical example: `apps/ezagent_domain_agent/lib/ezagent/entity/agent.ex` " <>
             "`spawn_fresh/4`."
  end

  defp lib_files do
    cwd = File.cwd!()

    roots =
      cond do
        File.dir?(Path.join(cwd, "apps")) ->
          [Path.join(cwd, "apps/*/lib/**/*.{ex,exs}")]

        File.dir?(Path.join([cwd, "..", "..", "apps"])) ->
          [Path.join(Path.expand("../..", cwd), "apps/*/lib/**/*.{ex,exs}")]

        true ->
          [Path.join(cwd, "**/*.{ex,exs}")]
      end

    roots
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.uniq()
    |> Enum.reject(fn path ->
      Enum.any?(@whitelist, fn w -> String.ends_with?(path, w) end)
    end)
  end
end
