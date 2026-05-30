defmodule EzagentCore.Invariants.EntitiesHaveWorkspaceTest do
  @moduledoc """
  Phase 9 PR-2 (SPEC v3 §3) — architectural invariant test.

  Every entity URI in the system MUST carry its workspace as the first
  path segment under the type axis: `entity://<type>/<workspace>/<name>`.
  The previous 2-segment form (`entity://user/admin`) is rejected by
  `Ezagent.URI.new!/1` at parse time.

  This test guards against three regressions:

  1. **Parser regression**: someone weakens `parse!/1` to accept
     2-segment entity URIs again (silent tenant leak).
  2. **Helper regression**: `entity_workspace_uri/1` returns the wrong
     workspace URI (silent cross-workspace dispatch).
  3. **Code-base drift**: a future PR introduces a hardcoded 2-segment
     entity URI string anywhere in `apps/` (would break parse at first
     reference).

  See `docs/superpowers/specs/2026-05-21-phase-9-tenant-isolation-design.md`
  §3 + §9 PR-2 row.

  Pattern after `apps/ezagent_core/test/invariants/sessions_have_workspace_test.exs`.
  """
  use ExUnit.Case, async: true

  describe "Ezagent.URI.new!/1 — SPEC v3 §3.2 enforcement" do
    test "rejects 2-segment entity URI with `workspace segment` in message" do
      # NOTE: literal `entity://user/admin` constructed via string
      # concatenation so the bulk-rewrite never silently 3-segments it.
      legacy = "entity://user/" <> "admin"

      err =
        assert_raise ArgumentError, fn ->
          Ezagent.URI.new!(legacy)
        end

      assert err.message =~ "workspace segment"
    end

    test "accepts 3-segment entity URI" do
      # SPEC #324: tenant users live in workspace://<tenant>, not the
      # deleted `default`. Use team-alpha to pin the
      # "workspace segment in path" invariant.
      uri = Ezagent.URI.new!("entity://user/team-alpha/allen")
      assert uri.scheme == "entity"
      assert uri.host == "user"
      assert uri.path == "/team-alpha/allen"
    end
  end

  describe "Ezagent.URI.entity_workspace_uri/1 — SPEC v3 §3.3" do
    test "extracts workspace URI from tenant-workspace user entity" do
      uri = Ezagent.URI.new!("entity://user/team-alpha/allen")
      assert Ezagent.URI.entity_workspace_uri(uri) == URI.new!("workspace://team-alpha")
    end

    test "extracts workspace URI from cross-workspace agent entity" do
      uri = Ezagent.URI.new!("entity://agent/team-alpha/cc_demo")
      assert Ezagent.URI.entity_workspace_uri(uri) == URI.new!("workspace://team-alpha")
    end

    test "extracts workspace://system URI from admin entity (Phase 9 PR-8)" do
      uri = Ezagent.URI.new!("entity://user/system/admin")
      assert Ezagent.URI.entity_workspace_uri(uri) == URI.new!("workspace://system")
    end

    test "ignores query string when extracting workspace" do
      uri = Ezagent.URI.new!("entity://user/team-alpha/allen?action=identity.list_caps")
      assert Ezagent.URI.entity_workspace_uri(uri) == URI.new!("workspace://team-alpha")
    end
  end

  describe "codebase grep gate — no 2-segment entity URIs in apps/" do
    @spec_doc_dir Path.expand(Path.join(__DIR__, "../../../../docs"))

    test "no `entity://(user|agent)/<name>` 2-segment literals outside docs/" do
      # Walk every .ex / .exs under apps/, skip the spec / docs trees,
      # and assert no 2-segment entity URI literal remains. Phase 9
      # PR-2 is the cutover migration; any new occurrence is a
      # regression that would break parse!/1 at runtime.
      apps_dir = Path.expand(Path.join(__DIR__, "../../../../apps"))

      offenders =
        apps_dir
        |> walk_source_files()
        |> Enum.flat_map(&scan_file_for_legacy_entity_uris/1)

      assert offenders == [],
             """
             Found legacy 2-segment entity URIs in source files:

             #{Enum.map_join(offenders, "\n", &format_offender/1)}

             Phase 9 PR-2 (SPEC v3 §3): every `entity://<type>/<name>`
             literal must be `entity://<type>/<workspace>/<name>`. Tests
             that intentionally exercise the 2-segment rejection path
             must construct the URI via string concatenation:

                 legacy = "entity://user/" <> "admin"

             so the grep + bulk-rewrite tooling skips them. See
             `Ezagent.URI.new!/1` rejection cases in
             `apps/ezagent_core/test/ezagent/uri_test.exs`.
             """
    end

    # Recursively walk a directory, returning every .ex / .exs file.
    defp walk_source_files(dir) do
      cond do
        File.dir?(dir) ->
          dir
          |> File.ls!()
          |> Enum.reject(fn name ->
            name in ["_build", "deps", "node_modules", ".elixir_ls"] or
              String.starts_with?(name, ".")
          end)
          |> Enum.flat_map(fn child -> walk_source_files(Path.join(dir, child)) end)

        File.regular?(dir) and (String.ends_with?(dir, ".ex") or String.ends_with?(dir, ".exs")) ->
          [dir]

        true ->
          []
      end
    end

    defp scan_file_for_legacy_entity_uris(path) do
      # 2-segment match: entity://(user|agent)/<name> where <name> is
      # NOT followed by `/` (which would make it 3-segment) and NOT
      # followed by more identifier chars (which would extend the
      # match). Negative lookahead allowed in Erlang :re for this case.
      #
      # `#` is in the exclusion set so an interpolation-continued segment
      # (`entity://user/uc-parity-#{n}/alice` — a CANONICAL 3-segment URI
      # whose workspace segment is dynamic) is not mis-flagged as a
      # terminal 2-segment literal. A genuine 2-segment literal like
      # `"entity://user/admin"` is still caught (next char is `"`, not
      # an identifier/`#`).
      regex = ~r{entity://(?:user|agent)/[a-zA-Z0-9][a-zA-Z0-9_-]*(?![a-zA-Z0-9_./#-])}

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
      |> Enum.reject(&intentional_negative_case?/1)
    end

    # Skip pure comment lines + docstring lines — comments are
    # documentation, not code that gets parsed. We still flag any
    # 2-segment URI in actual code (def, assign, function calls).
    defp comment_line?(line) do
      trimmed = String.trim(line)
      # Lines starting with #, or inside a moduledoc/doc heredoc.
      # The heuristic is conservative: any line whose first non-blank
      # char is `#` is a comment. Heredoc detection per-file is
      # complex; instead we filter for the pattern `entity://X/Y` in
      # any context that's clearly prose — see also `intentional_negative_case?/1`.
      String.starts_with?(trimmed, "#")
    end

    # Tests that deliberately exercise the rejection path build the URI
    # via concatenation, e.g.:
    #
    #     legacy = "entity://user/" <> "admin"
    #
    # The grep above doesn't match that form (because there's a `"` in
    # between). For prose lines inside @moduledoc/@doc heredocs that
    # mention the legacy form, we also skip the file's own self-
    # references.
    defp intentional_negative_case?({path, _line_no, line, _uri}) do
      # The test itself (this file + uri_test.exs) discusses the legacy
      # form in prose. Skip those self-references — we already verify
      # the rejection via assert_raise.
      basename = Path.basename(path)

      basename in [
        "entities_have_workspace_test.exs",
        "uri_test.exs"
      ] and
        String.contains?(line, ["NOTE:", "form is the point", "rejected by", "moduledoc"])
    end

    defp format_offender({path, line_no, line, uri}) do
      rel = Path.relative_to(path, Path.expand(Path.join(__DIR__, "../../../..")))
      "  #{rel}:#{line_no}\n    URI: #{uri}\n    line: #{String.trim(line)}"
    end

    # Acknowledge the docs-tree spec dir without using it at runtime
    # (helps readers find the related spec). The grep gate intentionally
    # never touches `docs/`.
    @doc false
    def spec_doc_dir, do: @spec_doc_dir
  end
end
