defmodule EzagentCore.Invariants.NoNilWorkspaceWritesTest do
  @moduledoc """
  Phase 9 PR-6 (SPEC v3 §7.3) — write-time invariant — no insert can
  succeed without populating `workspace_uri`.

  Two enforcement layers, both pinned here:

  1. **DB-level (NOT NULL)** — programmatic test inserts each
     per-tenant schema struct WITHOUT `workspace_uri` and asserts the
     insert fails with the SQLite NOT NULL constraint error.

  2. **Code-side (grep gate)** — scans `apps/**/lib/**.ex` for
     `Repo.insert(_all)?(...)` call sites; for each call site against
     a per-tenant table, asserts the call site also references
     `workspace_uri` (either as a key in the inserted attrs or in the
     surrounding 10 lines of context). This catches the regression
     "PR-N adds a new write path, forgets to set workspace_uri at
     compile time but only crashes at runtime when the data is
     non-default."

  ## Why two layers

  Layer 1 alone misses the lateness of detection — a missed write site
  fails only when production traffic hits it. Layer 2 catches the
  missing key statically during PR review. Together they make
  drift-by-omission a CI-time failure, not a runtime one.
  """

  use EzagentCore.DataCase, async: false

  # ezagent_core can only see ezagent_core schemas at compile time.
  # `Ezagent.Users`, `Ezagent.Entity.Token`, `Ezagent.Entity.Profile`
  # live in `ezagent_domain_identity` — their DB-level enforcement is
  # exercised in
  # `apps/ezagent_domain_identity/test/invariants/no_nil_workspace_writes_identity_test.exs`.

  describe "DB-level NOT NULL enforcement (core schemas)" do
    test "messages without workspace_uri raises NOT NULL violation" do
      msg =
        %Ezagent.Message{
          id: "test-no-ws-msg",
          sender: URI.new!("entity://system/user/admin"),
          mentions: [],
          body: %{text: "x", attachments: []},
          inserted_at: DateTime.utc_now()
          # workspace_uri intentionally omitted
        }

      assert {:error, _changeset_or_constraint} =
               safe_insert(msg)
    end

    test "kind_snapshots without workspace_uri raises NOT NULL violation" do
      row =
        %Ezagent.Ecto.KindSnapshot{
          uri: "entity://team-alpha/user/no-ws-snapshot",
          kind_type: "user",
          state_binary: :erlang.term_to_binary(%{}),
          version: 0,
          inserted_at: DateTime.utc_now(),
          updated_at: DateTime.utc_now()
          # workspace_uri intentionally omitted
        }

      assert {:error, _} = safe_insert(row)
    end
  end

  describe "code-side grep gate" do
    test "every Repo.insert / Repo.insert! against a per-tenant schema sets workspace_uri" do
      offenders = scan_for_nil_workspace_writes()

      assert offenders == [],
             """
             The following Repo.insert(!) call sites against per-tenant
             schemas don't appear to set `workspace_uri`:

             #{format_offenders(offenders)}

             Fix each: derive workspace via
             `Ezagent.Persistence.workspace_uri_for!/1` (entity / session
             URI). For cross-cutting writers (audit / snapshot of
             `system://` URIs), inline the literal `"workspace://system"`
             at the write site with a comment explaining why — per SPEC
             #324 rev 3, no global `default_workspace_uri/0` helper
             exists (the silent-fallback bug class Allen deleted).

             If a call site is legitimately writing system-scope data and
             needs to bypass this rule, add the comment
             `# workspace_uri: <reason>` on the same or adjacent line.
             """
    end
  end

  # ---------------------------------------------------------------------
  # Helpers

  defp safe_insert(struct) do
    EzagentCore.Repo.insert(struct)
  rescue
    e in Ecto.ConstraintError -> {:error, e}
    e in Exqlite.Error -> {:error, e}
    e -> {:error, e}
  end

  # Per-tenant schemas (sync with PerTenantTablesHaveWorkspaceColumnTest).
  # We check for fully-qualified module names + tightly-scoped aliases
  # that imply our per-tenant schema. Generic words like "Token" /
  # "Profile" are NOT in the alias list — they're too ambiguous and
  # cause false positives across the codebase.
  @per_tenant_schemas [
    "Ezagent.Message",
    "Ezagent.Ecto.KindSnapshot",
    "Ezagent.Users",
    "Ezagent.Entity.Token",
    "Ezagent.Entity.Profile"
  ]

  # Module aliases / short forms that count as per-tenant references
  # at write sites. KEEP THIS TIGHT — false positives drown out true
  # offenders.
  @per_tenant_aliases [
    # `%Message{}` literal (only Message in scope is Ezagent.Message
    # inside MessageStore and a few callers).
    "%Message{",
    # `Message`-followed-by-comma in `Repo.insert(Message, ...)`
    "Message,",
    # `KindSnapshot.upsert` — the only KindSnapshot reference.
    "KindSnapshot."
  ]

  # Acceptable bypass marker — a comment that explicitly opts out of the
  # workspace_uri check (e.g. for migration seed inserts).
  @bypass_marker "workspace_uri:"

  defp scan_for_nil_workspace_writes do
    lib_files = Path.wildcard("apps/*/lib/**/*.ex")

    Enum.flat_map(lib_files, fn path ->
      lines = File.read!(path) |> String.split("\n")
      scan_file_lines(path, lines)
    end)
  end

  defp scan_file_lines(path, lines) do
    indexed = Enum.with_index(lines, 1)

    Enum.reduce(indexed, [], fn {line, lineno}, acc ->
      cond do
        not String.contains?(line, "Repo.insert") ->
          acc

        # Only flag writes that mention a per-tenant module on this line.
        not mentions_per_tenant_schema?(line) ->
          acc

        # The 10 lines before + this line are the "context window" — the
        # workspace_uri assignment usually lives in the changeset or
        # struct literal above.
        contextual_window_has_workspace?(lines, lineno) ->
          acc

        true ->
          [%{path: path, lineno: lineno, line: String.trim(line)} | acc]
      end
    end)
  end

  defp mentions_per_tenant_schema?(line) do
    Enum.any?(@per_tenant_schemas, &String.contains?(line, &1)) or
      Enum.any?(@per_tenant_aliases, &String.contains?(line, &1))
  end

  defp contextual_window_has_workspace?(lines, lineno) do
    # Look 15 lines back + 5 lines forward (changeset assignment can
    # follow `|> Repo.insert` in some patterns).
    from = max(0, lineno - 15)
    to = min(length(lines), lineno + 5)

    Enum.slice(lines, from..to)
    |> Enum.any?(&String.contains?(&1, @bypass_marker))
  end

  defp format_offenders(offenders) do
    Enum.map_join(offenders, "\n", fn %{path: p, lineno: l, line: line} ->
      "  #{p}:#{l}  #{line}"
    end)
  end
end
