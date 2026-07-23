defmodule Ezagent.Invariants.AllPerTenantURIsHaveWorkspaceTest do
  @moduledoc """
  Phase 9 PR-7 (SPEC v3 §3.6) — architectural invariant test.

  Per Amendment 2 (Allen 2026-05-21): every per-tenant URI scheme
  carries its workspace as the authority. After this refactor,
  the unified shape is

      <scheme>://<workspace>/<type>/<name>

  for `entity://`, `session://`, `template://`, `resource://`.
  Cross-cutting schemes (`workspace://`, `system://`) keep their
  pre-PR-7 shape.

  This test guards four regressions:

  1. **Parser regression** — `Ezagent.URI.new!/1` weakens to accept
     2-segment URIs again (silent tenant leak).
  2. **Capability regression** — `Ezagent.Capability.workspace_of/1`
     for a unified scheme stops returning the URI's path segment.
  3. **WorkspaceRegistry drift** — registry binding for a session URI
     diverges from the URI's workspace segment.
  4. **Code-base drift** — a future PR introduces a hardcoded
     2-segment URI literal in `apps/` (would break parse at first
     reference).
  """
  use ExUnit.Case, async: true

  describe "Ezagent.URI.new!/1 — SPEC v3 §3.6 enforcement" do
    test "rejects 2-segment session URI" do
      # Literal `session://default/main` constructed via `<>` so the
      # bulk-rewrite tool doesn't silently 3-segment it.
      legacy = "session://default/" <> "main"

      assert_raise ArgumentError, ~r/type and name segments/, fn ->
        Ezagent.URI.new!(legacy)
      end
    end

    test "rejects 2-segment template URI" do
      legacy = "template://agent/" <> "cc-orch"

      assert_raise ArgumentError, ~r/type and name segments/, fn ->
        Ezagent.URI.new!(legacy)
      end
    end

    test "rejects 2-segment resource URI" do
      legacy = "resource://uploads/" <> "abc"

      assert_raise ArgumentError, ~r/type and name segments/, fn ->
        Ezagent.URI.new!(legacy)
      end
    end

    test "accepts 3-segment session URI" do
      uri = Ezagent.URI.new!("session://system/default/main")
      assert uri.scheme == "session"
      assert uri.host == "system"
      assert uri.path == "/default/main"

      assert Ezagent.Capability.workspace_of(uri) |> URI.to_string() ==
               "workspace://system"
    end

    test "accepts 3-segment template URI" do
      uri = Ezagent.URI.new!("template://team-alpha/agent/cc-orchestrator")
      assert uri.scheme == "template"
      assert uri.host == "team-alpha"
      assert uri.path == "/agent/cc-orchestrator"

      assert Ezagent.Capability.workspace_of(uri) |> URI.to_string() ==
               "workspace://team-alpha"
    end

    test "accepts 3-segment resource URI" do
      uri = Ezagent.URI.new!("resource://team-alpha/uploads/file-abc")

      assert Ezagent.Capability.workspace_of(uri) |> URI.to_string() ==
               "workspace://team-alpha"
    end

    test "workspace:// (1-seg) unchanged — tenant root" do
      uri = Ezagent.URI.new!("workspace://team-alpha")
      assert uri.scheme == "workspace"
      assert uri.host == "team-alpha"
    end

    test "system:// (2-seg) unchanged — cross-workspace" do
      uri = Ezagent.URI.new!("system://routing/default")
      assert uri.scheme == "system"
      assert uri.host == "routing"
      assert uri.path == "/default"

      assert Ezagent.Capability.workspace_of(uri) == :any
    end
  end

  describe "WorkspaceRegistry consistency (SPEC v3 §3.6 PR-7)" do
    test "binding equals URI workspace segment" do
      session_uri =
        "session://team-alpha/default/all-per-tenant-#{System.unique_integer([:positive])}"

      Ezagent.WorkspaceRegistry.bind(session_uri, "workspace://team-alpha")

      {:ok, bound} = Ezagent.WorkspaceRegistry.lookup(Ezagent.URI.new!(session_uri))

      uri_workspace = Ezagent.Capability.workspace_of(Ezagent.URI.new!(session_uri))

      assert URI.to_string(uri_workspace) == URI.to_string(bound),
             "WorkspaceRegistry cache must agree with URI workspace segment"
    end

    test "Capability.workspace_of extracts structurally — no registry lookup" do
      # PR-7 SoT-to-cache demotion: an unbound session still resolves to
      # the workspace in its URI path.
      session_uri =
        Ezagent.URI.new!(
          "session://team-beta/default/unbound-#{System.unique_integer([:positive])}"
        )

      # Deliberately NO WorkspaceRegistry.bind.
      ws = Ezagent.Capability.workspace_of(session_uri)
      assert URI.to_string(ws) == "workspace://team-beta"
    end
  end

  describe "codebase grep gate — no 2-segment unified-scheme URIs in apps/lib" do
    test "no `session://<X>` 1-or-2-segment literals outside docs/" do
      offenders = scan_apps(~r{session://(?:[a-zA-Z][a-zA-Z0-9_-]*)(?![/a-zA-Z0-9_.-])})

      assert offenders == [],
             """
             Found legacy 1-segment session URIs in source files:

             #{Enum.map_join(offenders, "\n", &format_offender/1)}

             Phase 9 PR-7 (SPEC v3 §3.6): every `session://<X>` literal
             must be `session://<workspace>/<type>/<name>`. Tests
             that intentionally exercise the 2-segment rejection path
             must construct the URI via string concatenation:

                 legacy = "session://default/" <> "main"

             so the grep + bulk-rewrite tooling skips them.
             """
    end

    test "no `session://<X>/<Y>` 2-segment literals outside docs/" do
      offenders =
        scan_apps(
          ~r{session://(?:[a-zA-Z][a-zA-Z0-9_-]*)/(?:[a-zA-Z][a-zA-Z0-9_-]*)(?![/a-zA-Z0-9_.-])}
        )

      assert offenders == [],
             """
             Found legacy 2-segment session URIs in source files:

             #{Enum.map_join(offenders, "\n", &format_offender/1)}
             """
    end

    test "no `template://(agent|session)/<X>` 2-segment literals outside docs/" do
      offenders =
        scan_apps(
          ~r{template://(?:agent|session)/(?:[a-zA-Z][a-zA-Z0-9_.@-]*)(?![/a-zA-Z0-9_.@-])}
        )

      assert offenders == [],
             """
             Found legacy 2-segment template URIs in source files:

             #{Enum.map_join(offenders, "\n", &format_offender/1)}
             """
    end

    test "no `resource://<X>/<Y>` 2-segment literals outside docs/" do
      offenders =
        scan_apps(
          ~r{resource://(?:[a-zA-Z][a-zA-Z0-9_-]*)/(?:[a-zA-Z][a-zA-Z0-9_-]*)(?![/a-zA-Z0-9_.-])}
        )

      assert offenders == [],
             """
             Found legacy 2-segment resource URIs in source files:

             #{Enum.map_join(offenders, "\n", &format_offender/1)}
             """
    end

    # ---------------------------------------------------------------------

    defp scan_apps(regex) do
      apps_dir = Path.expand(Path.join(__DIR__, "../../../../apps"))

      apps_dir
      |> walk_source_files()
      |> Enum.flat_map(&scan_file(&1, regex))
    end

    defp walk_source_files(dir) do
      cond do
        File.dir?(dir) ->
          dir
          |> File.ls!()
          |> Enum.reject(fn name ->
            name in ["_build", "deps", "node_modules", ".elixir_ls", "tmp"] or
              String.starts_with?(name, ".")
          end)
          |> Enum.flat_map(fn child -> walk_source_files(Path.join(dir, child)) end)

        File.regular?(dir) and (String.ends_with?(dir, ".ex") or String.ends_with?(dir, ".exs")) ->
          [dir]

        true ->
          []
      end
    end

    defp scan_file(path, regex) do
      basename = Path.basename(path)

      # Skip the test file we're running in + the URI tests + the
      # entities-have-workspace test that all deliberately discuss the
      # rejected forms in prose.
      skip_files =
        ~w(all_per_tenant_uris_have_workspace_test.exs uri_test.exs entities_have_workspace_test.exs workspace_isolation_test.exs)

      if basename in skip_files do
        []
      else
        path
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.flat_map(fn {line, line_no} ->
          cond do
            comment_line?(line) ->
              []

            true ->
              case Regex.scan(regex, line) do
                [] -> []
                matches -> Enum.map(matches, fn [m | _] -> {path, line_no, line, m} end)
              end
          end
        end)
      end
    end

    defp comment_line?(line) do
      trimmed = String.trim(line)
      String.starts_with?(trimmed, "#") or String.starts_with?(trimmed, "//")
    end

    defp format_offender({path, line_no, line, uri}) do
      rel = Path.relative_to(path, Path.expand(Path.join(__DIR__, "../../../..")))
      "  #{rel}:#{line_no}\n    URI: #{uri}\n    line: #{String.trim(line)}"
    end
  end
end
