defmodule EzagentCore.Invariants.WorkspaceSotTest do
  @moduledoc """
  Workspace single-source-of-truth (SoT) invariant — operator-facing
  LV / web code must use `Ezagent.Workspace.list_visible/0`, never
  `list_persisted/0` / `Workspace.Store.list_all/0`.

  ## Why

  Phase 9 PR-8 (SPEC v3 §13.1) introduced `workspace://system` with
  `visible: false`. The system workspace stays out of the regular
  operator-facing dropdown (and any other workspace lister) because
  membership in it carries cross-workspace authority — leaking it
  to a non-admin user via a `list_persisted/0` call would be a
  privilege-disclosure surface (the user sees they could be added
  to it, even if they can't add themselves).

  Per `docs/notes/2026-05-24-architecture-audit-v1.md` Finding 4:
  the discipline ("use `list_visible/0`, never `list_persisted/0`")
  was enforced by convention only. PR #290 fixed `workspaces_live.ex`
  after one regression; without an invariant test, the next LV that
  lists workspaces re-lands the same bug silently.

  This test fails when any production file under
  `apps/ezagent_plugin_liveview/lib` or `apps/ezagent_web/lib` (the
  operator-facing scope) references `list_persisted/0` or
  `Workspace.Store.list_all/0` without explicit exemption.

  Per memory `feedback_completion_requires_invariant_test`:
  "completion claim requires invariant test" — the architectural
  goal is "operator-facing surfaces use only the visible-workspaces
  view". This test is the gate; "PR-merges + tests-pass" alone
  doesn't catch the next regression.

  ## Allowlist

  Empty by default — `workspace_sot_test.exs` should reject every
  operator-scope `list_persisted/0` / `Workspace.Store.list_all/0`
  reference outright. Admin-only files live in admin sub-paths
  (`.../admin/`) but currently NONE of them call these functions:
  admin LVs that need cross-visibility use `Ezagent.Workspace.list_all/0`
  on the underlying domain module, which is a DIFFERENT function
  (the public list-everything API).

  If a future admin-only file genuinely needs `list_persisted/0`
  (e.g. a system-workspace diagnostic LV), add it to `@allowlist`
  with a one-line justification — and verify it lives under a
  `live_session :require_admin` route in
  `apps/ezagent_web/lib/ezagent_web/router.ex`.
  """

  use ExUnit.Case, async: true

  # Operator-facing scope: every production file under these
  # `lib/` trees is checked. Admin scope is identified by
  # `live_session :require_admin` in `router.ex`; files mounted
  # under that scope ARE included here (they should still use
  # `list_visible/0` — admins seeing the system workspace via a
  # different code path is fine).
  @scoped_roots [
    "apps/ezagent_plugin_liveview/lib",
    "apps/ezagent_web/lib"
  ]

  # Forbidden patterns — both must be absent from every operator-
  # facing file unless explicitly allowlisted below.
  #
  # `Workspace.list_persisted/0` returns ALL workspace rows including
  # `visible: false` ones; `Workspace.Store.list_all/0` is the
  # underlying Store-level call (skipping the domain function gate).
  @forbidden_patterns [
    {~r/(?<![\w\.])Workspace\.list_persisted\s*\(/,
     "Workspace.list_persisted/0 leaks visible:false workspaces"},
    {~r/(?<![\w\.])Workspace\.Store\.list_all\s*\(/,
     "Workspace.Store.list_all/0 bypasses the visible-workspaces filter"}
  ]

  # Files exempted from the forbidden patterns. Each entry MUST
  # be justified in a one-line comment and the file MUST be under
  # an admin-only `live_session :require_admin` route.
  #
  # The list is currently empty by design — NO operator-facing file
  # genuinely needs `list_persisted/0` or `Workspace.Store.list_all/0`.
  # The sentinel string never matches a real file path; it exists so
  # the `in @allowlist` check stays typed as `[binary()]` (Elixir's
  # type system narrows `[]` to "never matches", emitting a warning).
  @allowlist ["__sentinel_never_matches__"]

  test "no operator-facing LV/web file references list_persisted/0 or Store.list_all/0" do
    apps_root = Path.expand("../../../..", __DIR__)

    violations =
      @scoped_roots
      |> Enum.flat_map(fn rel_root ->
        full = Path.join(apps_root, rel_root)

        if File.dir?(full) do
          list_ex_files(full)
          |> Enum.map(&Path.relative_to(&1, apps_root))
        else
          []
        end
      end)
      |> Enum.flat_map(fn rel_path ->
        if rel_path in @allowlist do
          []
        else
          content_no_comments = read_stripping_comments(Path.join(apps_root, rel_path))

          Enum.flat_map(@forbidden_patterns, fn {regex, reason} ->
            if Regex.match?(regex, content_no_comments) do
              [{rel_path, reason}]
            else
              []
            end
          end)
        end
      end)

    assert violations == [],
           """
           Operator-facing LV/web files referencing forbidden workspace listers:

             #{format_violations(violations)}

           Use `Ezagent.Workspace.list_visible/0` instead. `list_persisted/0`
           and `Workspace.Store.list_all/0` return `visible: false` workspaces
           (the system workspace) and leak them to non-admin operators.

           Per docs/notes/2026-05-24-architecture-audit-v1.md Finding 4 + memory
           `feedback_completion_requires_invariant_test`.

           If your file is genuinely admin-only (mounted under
           `live_session :require_admin` in router.ex) AND needs the unfiltered
           list, add it to `@allowlist` here with a justification.
           """
  end

  test "Ezagent.Workspace.list_visible/0 is exported (no fallback path needed)" do
    # The dead-fallback cleanup in `live_auth.ex` assumes
    # `list_visible/0` is always available. If a future refactor
    # removes the export, this test fails loudly — preventing a
    # silent regression where the operator-facing dropdown returns
    # `[]` and forces operators into the admin drawer to see
    # any workspace at all.
    assert Code.ensure_loaded?(Ezagent.Workspace),
           "Ezagent.Workspace must be loadable for the operator-facing dropdown"

    assert function_exported?(Ezagent.Workspace, :list_visible, 0),
           "Ezagent.Workspace.list_visible/0 must be exported — the SoT for " <>
             "operator-facing workspace listing"
  end

  # --- helpers -------------------------------------------------------------

  defp read_stripping_comments(full_path) do
    full_path
    |> File.read!()
    |> String.split("\n")
    |> Enum.reject(&Regex.match?(~r/^\s*#/, &1))
    |> Enum.join("\n")
  end

  defp list_ex_files(dir) do
    dir
    |> File.ls!()
    |> Enum.flat_map(fn entry ->
      full = Path.join(dir, entry)

      cond do
        File.dir?(full) -> list_ex_files(full)
        String.ends_with?(entry, ".ex") -> [full]
        true -> []
      end
    end)
  end

  defp format_violations(violations) do
    violations
    |> Enum.map(fn {path, reason} -> "#{path} — #{reason}" end)
    |> Enum.join("\n             ")
  end
end
