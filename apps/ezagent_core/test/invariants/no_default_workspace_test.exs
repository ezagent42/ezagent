defmodule Ezagent.Invariants.NoDefaultWorkspaceTest do
  @moduledoc """
  SPEC #324 (workspace `default` → `system` rename) — locking gate.

  Fails CI if any production lib file (`apps/*/lib/**/*.{ex,exs}`)
  contains one of the legacy default-workspace literals or the
  `:workspace, "default"` Keyword-default fallback pattern. This is
  the architectural-goal invariant per
  `feedback_completion_requires_invariant_test` — without it, the next
  PR silently re-introduces the silent default that PR #324 was created
  to remove.

  ## What the SPEC banned

  1. `workspace://default` (the bare URI literal) — admin's workspace
     is `system`, not `default`. Tenants get explicit names.
  2. `session://<template>/default/<name>` — sessions in any template
     hardcoding the `default` workspace segment.
  3. `entity://(user|agent)/default/<name>` — per-tenant entity URIs
     hardcoding `default`.
  4. `template://(session|agent)/default/<name>` — template URIs hard-
     coding `default`.
  5. `resource://<type>/default/<name>` — resource URIs hardcoding
     `default`.
  6. `:workspace, "<any-string>"` — `Keyword.get(opts, :workspace, _)`
     with any string default. Per SPEC #324 rev 3 (Allen 2026-05-25),
     ANY workspace fallback is wrong — including the rename target
     `"system"`. Production code MUST raise on missing workspace.
  7. `workspace: "<any-string>"` — Keyword-list / map literal default.
  8. `Map.get(_, :workspace, "<string>")` — Map-shaped silent fallback.
  9. `.default_workspace_uri()` — call to the deleted global helper.
     The function was removed in SPEC #324 rev 3; cross-cutting writers
     (audit / snapshot of `system://` URIs) MUST inline the literal
     `"workspace://system"` at the write site with a comment explaining
     why (a global helper hides "no workspace passed" bugs).
  10. `nil -> "system"` — silent nil-coercion in case-expression form.

  ## What is OK

  - `workspace://default-tenant` (or any `default-*` workspace name) —
     the negative lookahead in pattern 1 doesn't false-positive.
  - Comment prose using "the legacy default workspace" without the URI
     literal — humans need to reference the deleted concept.
  - Frozen historical migrations (whitelisted below).
  - This test itself (whitelisted below — it contains the forbidden
     patterns as data).

  ## Why scoped to `apps/*/lib/` and not `apps/*/test/`

  Production lib is the structural contract — a `:workspace, "default"`
  there is a silent production bug. Test fixtures that hardcode
  `workspace://default` are tests of the legacy behavior; they get
  rewritten in the same PR but are not invariant-gated. If a test
  re-introduces the literal in a future PR it's an explicit decision,
  not a structural leak.
  """

  use ExUnit.Case, async: true

  @forbidden [
    # 1. workspace://default (the bare URI literal — negative lookahead
    #    to permit workspace://default-tenant style names).
    {~r/workspace:\/\/default(?![a-zA-Z0-9_-])/, "legacy `workspace://default` literal"},
    # 2. session://<template>/default/<name>
    {~r/session:\/\/[^\/\s"']+\/default\//,
     "session URI hardcoding `/default/` workspace segment"},
    # 3. entity://(user|agent)/default/<name>
    {~r/entity:\/\/(?:user|agent)\/default\//,
     "entity URI hardcoding `/default/` workspace segment"},
    # 4. template://(session|agent)/default/<name>
    {~r/template:\/\/(?:session|agent)\/default\//,
     "template URI hardcoding `/default/` workspace segment"},
    # 5. resource://<type>/default/<name>
    {~r/resource:\/\/[^\/\s"']+\/default\//,
     "resource URI hardcoding `/default/` workspace segment"},
    # 6. Keyword default — `Keyword.get(opts, :workspace, "default")` or
    #    `Keyword.get(opts, :workspace, "system")` — any string default
    #    for :workspace is a silent fallback (SPEC #324 rev 3 — Allen
    #    2026-05-25). Production code MUST raise on missing workspace.
    {~r/:workspace,\s*"[^"]+"/,
     "silent `Keyword.get(_, :workspace, \"<string>\")` fallback — must raise on missing"},
    # 7. Keyword-list literal `workspace: "default"` or `workspace: "system"`.
    {~r/workspace:\s*"(?!workspace:\/\/)[^"]+"/,
     "Keyword-list / map literal `workspace: \"<string>\"` — must raise on missing"},
    # 8. Map.get default for :workspace key — same bug class as
    #    Keyword.get above; covers `Map.get(params, :workspace, "system")`
    #    and `Map.get(params, "workspace", "system")`.
    {~r/Map\.get\([^,]+,\s*(?::workspace|"workspace"),\s*"[^"]+"\)/,
     "silent `Map.get(_, :workspace, \"<string>\")` fallback — must raise on missing"},
    # 9. The deleted `default_workspace_uri/0` function. Any reference
    #    is a regression — the function was removed in SPEC #324 rev 3.
    #    Allowed: comment prose mentioning the deleted name.
    {~r/\.default_workspace_uri\(\)/,
     "call to deleted `.default_workspace_uri/0` — function removed SPEC #324 rev 3"},
    # 10. `case _ do nil -> "system"` — silent nil→"system" coercion is
    #     the silent fallback pattern in case-expression form.
    {~r/nil\s*->\s*"system"/, "silent `nil -> \"system\"` coercion — must raise instead"}
  ]

  # Frozen historical migrations + this test itself. Paths are relative
  # to the umbrella root (`File.cwd!()` inside an umbrella app's test/
  # is the umbrella root when ExUnit launches via `mix test` at the
  # root level, but each per-app suite may run from `apps/<app>/`. We
  # accept BOTH path forms.)
  @whitelist [
    "apps/ezagent_core/priv/repo/migrations/20260601000000_phase9_pr6_workspace_uri_columns.exs",
    "priv/repo/migrations/20260601000000_phase9_pr6_workspace_uri_columns.exs",
    "apps/ezagent_core/test/invariants/no_default_workspace_test.exs",
    "test/invariants/no_default_workspace_test.exs"
  ]

  test "no production lib code references legacy default workspace literals or string fallbacks" do
    offenders =
      lib_files()
      |> Enum.flat_map(fn path ->
        lines = path |> File.read!() |> String.split("\n")

        Enum.with_index(lines, 1)
        |> Enum.flat_map(fn {line, ln} ->
          Enum.flat_map(@forbidden, fn {regex, label} ->
            if Regex.match?(regex, line) do
              ["#{path}:#{ln}: [#{label}] #{String.trim(line)}"]
            else
              []
            end
          end)
        end)
      end)

    assert offenders == [],
           "Found legacy default-workspace references (SPEC #324 forbids):\n\n" <>
             Enum.join(offenders, "\n") <>
             "\n\nFix each site by deriving workspace structurally from the caller URI " <>
             "(Ezagent.URI.entity_workspace_uri/1), passing workspace explicitly, or " <>
             "renaming the literal (admin context → \"system\", tenant context → an " <>
             "explicit tenant name like \"team-alpha\")."
  end

  # Scan every production .ex file under apps/*/lib/. Per SPEC #324 the
  # test fixtures (apps/*/test/) are NOT invariant-gated (they're
  # rewritten in the same PR but tolerated as opt-in for future legacy
  # behavior tests).
  defp lib_files do
    cwd = File.cwd!()

    # Support both umbrella-root and per-app run modes.
    roots =
      cond do
        # Running from the umbrella root (`mix test`).
        File.dir?(Path.join(cwd, "apps")) ->
          [Path.join(cwd, "apps/*/lib/**/*.{ex,exs}")]

        # Running from inside a per-app dir (`cd apps/foo && mix test`).
        # Walk back up to find the umbrella root.
        File.dir?(Path.join([cwd, "..", "..", "apps"])) ->
          [Path.join(Path.expand("../..", cwd), "apps/*/lib/**/*.{ex,exs}")]

        # Fallback — just glob from cwd.
        true ->
          [Path.join(cwd, "**/*.{ex,exs}")]
      end

    roots
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.uniq()
    |> Enum.reject(fn path ->
      Enum.any?(@whitelist, fn w ->
        # Match suffix — handles both abs and umbrella-rel paths.
        String.ends_with?(path, w)
      end)
    end)
  end
end
