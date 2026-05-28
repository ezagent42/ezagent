defmodule EzagentCore.Invariants.WorkspaceSotTest do
  @moduledoc """
  Operator-facing workspace listing invariant (SPEC
  2026-05-27-workspace-cap-based-visibility §4.2).

  ## Why

  Pre-SPEC (Phase 9 PR-8) `workspace://system` had `visible: false`
  and operator-facing code was required to call `list_visible/0`
  rather than `list_persisted/0` / `Store.list_all/0`. This was a
  CONVENTION-only discipline — one LV missed the rule and leaked
  the system workspace (PR #290 fix).

  Post-SPEC the `:visible` field is GONE. Visibility is cap-derived:
  `Ezagent.Workspace.list_workspaces_for(caller_uri, caps)` is the
  SINGLE operator-facing query. It is structurally caller-scoped,
  so an operator-facing surface cannot accidentally leak hidden
  workspaces.

  This invariant gates the new discipline:

  - Operator-facing files (LV, web, mix tasks) MUST use
    `Ezagent.Workspace.list_workspaces_for(`. They MUST NOT use the
    unscoped `Workspace.list_all(`, `Workspace.list_persisted(`, or
    `Workspace.Store.list_all(`.
  - System-internal callers (Loader, agent-flavor resolution,
    `mix ezagent.workspace.*` audit tasks) can use the unscoped
    APIs — see `@allowlist` justifications.

  Per `feedback_completion_requires_invariant_test`: this is the
  gate that fails if a future LV reaches for the unscoped lister.
  """

  use ExUnit.Case, async: true

  # Operator-facing scope.
  @scoped_roots [
    "apps/ezagent_plugin_liveview/lib",
    "apps/ezagent_web/lib"
  ]

  # Operator-tier mix tasks under any app.
  @mix_task_wildcard "apps/*/lib/mix/tasks/**/*.ex"

  # Forbidden — every operator-facing file must use
  # `list_workspaces_for/2` and NEVER any of the unscoped readers
  # (which would re-introduce the hidden-workspace leak the SPEC
  # was designed to make structurally impossible).
  #
  # Codex r1 review MED (2026-05-27): the regex must match BOTH the
  # alias form (`Workspace.list_all(`) AND the fully-qualified form
  # (`Ezagent.Workspace.list_all(`). The previous negative lookbehind
  # `(?<![\w\.])Workspace\.` rejected a preceding `.`, so
  # `Ezagent.Workspace.list_all(` escaped the gate. Capture the
  # `Ezagent.` prefix as optional + use a word-boundary-style
  # lookbehind that allows `.` only when it follows `Ezagent`.
  @forbidden_patterns [
    {~r/(?:^|[^\w.])(?:Ezagent\.)?Workspace\.list_persisted\s*\(/,
     "Workspace.list_persisted/0 was deleted — use list_workspaces_for/2"},
    {~r/(?:^|[^\w.])(?:Ezagent\.)?Workspace\.list_visible\s*\(/,
     "Workspace.list_visible/0 was deleted — use list_workspaces_for/2"},
    {~r/(?:^|[^\w.])(?:Ezagent\.)?Workspace\.list_all\s*\(/,
     "Workspace.list_all/0 is system-internal — operator surfaces must use list_workspaces_for/2"},
    {~r/(?:^|[^\w.])(?:Ezagent\.)?Workspace\.Store\.list_all\s*\(/,
     "Workspace.Store.list_all/0 is system-internal — operator surfaces must use list_workspaces_for/2"}
  ]

  # Files exempted. Each exemption MUST justify the bypass.
  #
  # The audit mix task `cleanup_cross_prefix_members` reads
  # `Store.list_all/0` because its job is to walk EVERY persisted
  # workspace at operator-shell-tier (not user-facing). The "audit
  # the universe" semantic is structurally distinct from operator-
  # listing.
  @allowlist [
    "apps/ezagent_domain_workspace/lib/mix/tasks/ezagent.workspace.cleanup_cross_prefix_members.ex"
  ]

  test "no operator-facing LV/web/mix-task file references unscoped workspace listers" do
    apps_root = Path.expand("../../../..", __DIR__)

    scoped_paths =
      Enum.flat_map(@scoped_roots, fn rel_root ->
        full = Path.join(apps_root, rel_root)

        if File.dir?(full) do
          list_ex_files(full)
          |> Enum.map(&Path.relative_to(&1, apps_root))
        else
          []
        end
      end)

    mix_task_paths =
      apps_root
      |> Path.join(@mix_task_wildcard)
      |> Path.wildcard()
      |> Enum.map(&Path.relative_to(&1, apps_root))

    violations =
      (scoped_paths ++ mix_task_paths)
      |> Enum.uniq()
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
           Operator-facing files referencing forbidden workspace listers:

             #{format_violations(violations)}

           Use `Ezagent.Workspace.list_workspaces_for(caller_uri, caps)`
           instead. The unscoped functions (`list_all/0`, `Store.list_all/0`)
           are system-internal (Loader, audit mix tasks) — they bypass the
           per-caller filter and surface workspaces the caller cannot reach.

           Per SPEC 2026-05-27-workspace-cap-based-visibility §4.2 +
           memory `feedback_completion_requires_invariant_test`.

           If your file is genuinely an audit/loader/system-internal
           surface, add it to `@allowlist` with justification.
           """
  end

  test "Ezagent.Workspace.list_workspaces_for/2 is exported" do
    assert Code.ensure_loaded?(Ezagent.Workspace),
           "Ezagent.Workspace must be loadable for the operator-facing listing"

    assert function_exported?(Ezagent.Workspace, :list_workspaces_for, 2),
           "Ezagent.Workspace.list_workspaces_for/2 must be exported — the " <>
             "SoT for operator-facing workspace listing per SPEC " <>
             "2026-05-27-workspace-cap-based-visibility"
  end

  # Codex r1 review MED (2026-05-27) — the previous lookbehind regex
  # rejected a preceding `.`, so `Ezagent.Workspace.list_all(` escaped
  # the gate. This meta-test asserts both alias and fully-qualified
  # forms ARE caught, AND legitimate non-matches (e.g. `MyWorkspace`
  # prefix or a comment scope reference) are NOT.
  test "@forbidden_patterns catch both alias and fully-qualified forms" do
    positives = [
      "Workspace.list_all(",
      "Ezagent.Workspace.list_all(",
      " Ezagent.Workspace.Store.list_all(",
      "  Workspace.list_visible(",
      "Ezagent.Workspace.list_persisted("
    ]

    negatives = [
      "MyWorkspace.list_all(",
      "Foo.Workspace.list_all(",
      "Other.Module.list_all(",
      "Workspace.list_workspaces_for(",
      "Ezagent.Workspace.list_workspaces_for("
    ]

    for line <- positives do
      assert Enum.any?(@forbidden_patterns, fn {regex, _} -> Regex.match?(regex, line) end),
             "Regex must catch: #{inspect(line)} — at least one forbidden pattern should match"
    end

    for line <- negatives do
      refute Enum.any?(@forbidden_patterns, fn {regex, _} -> Regex.match?(regex, line) end),
             "Regex must NOT match: #{inspect(line)} — false-positive in @forbidden_patterns"
    end
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
