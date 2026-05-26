defmodule Ezagent.Invariants.NoSilentDefaultWorkspaceTest do
  @moduledoc """
  SPEC #324 rev 3 — runtime workspace fallback gate (Allen 2026-05-26).

  Companion to `no_default_workspace_test.exs`. While that test catches
  the *literal* form (`workspace://default`, `:workspace, "system"`,
  `Map.get(_, :workspace, "...")`), this test catches the **runtime
  fallback** form that runs at request-time:

      workspace_name = workspace_uri.host || "default"
      workspace_name = workspace_uri.host || "system"

  Per Allen 2026-05-26 09:31 (verbatim): "如果没有提供workspace name,
  应该直接crash。现在已经没有了默认workspace这个概念" — there is no
  default workspace concept; missing workspace MUST raise, not silently
  pick one. The 14-site sweep that landed alongside this test deleted
  every such fallback; the gate keeps it that way.

  ## What is banned

  Any production lib expression of shape:

      <ident or chain ending in `workspace*.host`> || "<string-literal>"
      <ident or chain ending in `*workspace*.host`> || "<string-literal>"

  i.e. an `||` fallback whose left-hand side reads a workspace URI's
  host segment and whose right-hand side is a hard-coded string. The
  defensible rewrite is `raise ArgumentError, "..."` — see the canonical
  pattern in `apps/ezagent_domain_chat/lib/ezagent/entity/agent.ex`
  `spawn_fresh/4`.

  ## What is OK

  - Comment prose using the forbidden text (skipped: leading `#` lines).
  - Non-workspace `host` fields (`some_uri.host || "..."` where the var
    is not workspace-shaped).
  - `case workspace_uri.host do nil -> raise ...` (explicit raise form).
  - This test itself (whitelisted below).

  ## Why scoped to `apps/*/lib/` only

  Same scoping rationale as `no_default_workspace_test.exs`: production
  lib is the structural contract; test fixtures may exercise legacy
  shapes as opt-in regression-locking.
  """

  use ExUnit.Case, async: true

  # The forbidden runtime-fallback pattern: a `.host` access on a name
  # containing "workspace" (case-insensitive), followed by `|| "<literal>"`.
  # The `(?i)workspace` allows `workspace_uri`, `session_workspace`,
  # `Workspace.foo`, etc.; the `\.host` makes it specifically a URI host
  # access; the `\|\|\s*"[^"]+"` is the silent-default branch.
  @forbidden_pattern ~r/(?i)workspace[^.\s]*\.host\s*\|\|\s*"[^"]+"/

  @whitelist [
    "apps/ezagent_core/test/invariants/no_silent_default_workspace_test.exs",
    "test/invariants/no_silent_default_workspace_test.exs"
  ]

  test "no production lib has `<workspace_uri>.host || \"<literal>\"` silent fallback" do
    offenders =
      lib_files()
      |> Enum.flat_map(fn path ->
        lines = path |> File.read!() |> String.split("\n")

        Enum.with_index(lines, 1)
        |> Enum.flat_map(fn {line, ln} ->
          trimmed = String.trim_leading(line)

          cond do
            # Skip comments — prose may legitimately reference the
            # banned pattern when documenting why it was removed.
            String.starts_with?(trimmed, "#") ->
              []

            Regex.match?(@forbidden_pattern, line) ->
              ["#{path}:#{ln}: #{String.trim(line)}"]

            true ->
              []
          end
        end)
      end)

    assert offenders == [],
           "Found silent workspace fallbacks (SPEC #324 rev 3 forbids):\n\n" <>
             Enum.join(offenders, "\n") <>
             "\n\nPer Allen 2026-05-26: no default workspace concept exists. Rewrite each " <>
             "site as `workspace_name = workspace_uri.host || raise ArgumentError, \"...\"`. " <>
             "Canonical example: `apps/ezagent_domain_chat/lib/ezagent/entity/agent.ex` " <>
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
