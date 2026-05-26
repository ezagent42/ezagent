defmodule Ezagent.Invariants.NoSilentTemplateClassTest do
  @moduledoc """
  SPEC #366 — runtime template-class fallback gate (Allen 2026-05-26 02:43Z).

  Companion to `no_silent_default_workspace_test.exs` (PR #362). Same
  pattern, different slot: that test catches workspace-name silent
  fallbacks; this test catches **template-class** silent fallbacks in
  the per-tenant `session://<class>/<workspace>/<name>` /
  `template://<class>/<workspace>/<name>` /
  `resource://<class>/<workspace>/<name>` URI shape.

  Per Allen 2026-05-26 02:43Z (verbatim, paraphrased from the
  dispatcher prompt): "force operators to explicitly pick a
  template-class when creating a session. Eliminate the silent
  'default' template-class fallback." Per
  `feedback_let_it_crash_no_workarounds` — no `Keyword.get(opts,
  :template_name, "default")` shims, no "if missing, pick something
  sensible" branches. Missing class = `ArgumentError`.

  ## What is banned (2 sub-patterns)

  1. `Keyword.get(opts, :template_name, "<literal>")` — the canonical
     shim that lets every caller skip the choice. Catches the
     production lib site this PR (#366) fixed in
     `apps/ezagent_domain_chat/lib/ezagent_domain_chat.ex` and any
     future drift on similar surfaces (e.g. `:template_class`,
     `:class`).
  2. `defp <name-containing-template>(_), do: "<literal>"` — single-
     clause catch-all returning a string-literal class. Mirrors P4 in
     `no_silent_default_workspace_test.exs`; covers the
     `promote_to_3seg` fallback shape eliminated in
     `apps/ezagent_cli/lib/ezagent_cli/dispatch.ex`.

  ## What is OK

  - Comment prose using the forbidden text (skipped: leading `#`
    lines).
  - `Keyword.fetch!(opts, :template_name)` — the canonical
    let-it-crash rewrite.
  - A wrapper `require_template_name!/1` (or similar) that raises on
    missing key — explicit raise is fine.
  - `Keyword.get(opts, :template_name)` (no default value) — returns
    `nil`, callers handle.
  - This test itself (whitelisted below).

  ## Why scoped to `apps/*/lib/` only

  Same scoping rationale as `no_silent_default_workspace_test.exs`:
  production lib is the structural contract; test fixtures may
  legitimately exercise legacy shapes for regression-locking.

  ## Why per-file whole-source regex instead of per-line

  The pattern is single-line for both sub-patterns. We keep a per-file
  read (rather than per-line) for consistency with
  `no_silent_default_workspace_test.exs` and to keep comment-stripping
  centralized.
  """

  use ExUnit.Case, async: true

  # P1: `Keyword.get(opts, :template_name | :template_class | :class,
  # "<literal>")`. `(?i)` is unnecessary — atom keys are lowercase.
  # The literal-string requirement (`"…"`) is what makes this a
  # fallback; bare `Keyword.get(opts, :template_name)` (no third arg)
  # is fine and not matched.
  @keyword_get_default_pattern ~r/Keyword\.get\(\s*[a-z_]+\s*,\s*:(?:template_name|template_class|class)\s*,\s*"[^"]+"\s*\)/

  # P2: `defp <name-containing-template>(_), do: "default"` — single-
  # clause catch-all whose name contains "template" AND returns the
  # banned literal `"default"`. The name-must-contain-template clause
  # narrows to template-shaped helpers; the `"default"`-only literal
  # narrows further past UI/badge helpers like `defp
  # template_class_name(_), do: "—"` (em-dash for "no template" cell)
  # which is a render-time display string, not a fallback.
  #
  # Both conditions are necessary together; either alone false-positives.
  @defp_template_literal_pattern ~r/(?i)defp\s+[a-z_]*template[a-z_]*\([^)]*\)[^,]*,\s*do:\s*"default"/

  @forbidden_patterns [
    {@keyword_get_default_pattern,
     "Keyword.get(opts, :template_name|:template_class|:class, \"<literal>\") — must Keyword.fetch! or raise instead"},
    {@defp_template_literal_pattern,
     "defp <template>(_), do: \"<literal>\" — single-clause catch-all returning string default; must raise instead"}
  ]

  @whitelist [
    "apps/ezagent_core/test/invariants/no_silent_template_class_test.exs",
    "test/invariants/no_silent_template_class_test.exs"
  ]

  test "no production lib has any silent template-class fallback (2 sub-patterns)" do
    offenders =
      lib_files()
      |> Enum.flat_map(fn path ->
        # Strip comment lines so prose discussing the banned shape
        # doesn't false-positive.
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
           "Found silent template-class fallbacks (SPEC #366 forbids):\n\n" <>
             Enum.join(offenders, "\n\n") <>
             "\n\nPer Allen 2026-05-26: no silent `\"default\"` template-class. " <>
             "Rewrite each site to `Keyword.fetch!(opts, :template_name)` or a " <>
             "helper that raises ArgumentError with an operator-facing message. " <>
             "Canonical examples:\n" <>
             "  * `apps/ezagent_domain_chat/lib/ezagent_domain_chat.ex` " <>
             "(`require_template_name!/1`)\n" <>
             "  * `apps/ezagent_cli/lib/ezagent_cli/dispatch.ex` " <>
             "(`require_template_class!/3` raises with `--template-class <class>` hint)"
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
