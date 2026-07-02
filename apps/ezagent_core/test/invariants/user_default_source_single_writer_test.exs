defmodule Ezagent.Invariants.UserDefaultSourceSingleWriterTest do
  @moduledoc """
  #17 cascade PR-0 (spec §5.2, codex H2) — structural single-writer invariant for the
  user default credential-source pointer.

  After the H2 fix there is NO exported cap-less mutator anywhere: the validate-and-
  persist body (including the `EzagentCore.Repo.insert`) lives INSIDE the cap-checked +
  audited handler `Ezagent.ActionSet.UserDefaultCredentialSource`. The core store
  `Ezagent.Credential.UserDefaultSource` is a pure data + read module (schema,
  `resolve/3`, a pure `changeset/2` builder, and the `set_via_dispatch/3` dispatch
  helper — none of which write).

  Per codex ("scan for direct writes to the table and same-file wrappers, not just
  textual call sites") this gate scans `*.ex` lib files for any **mutating Repo
  operation** (`Repo.insert` / `Repo.update` / `Repo.delete` and their `_all` variants)
  that targets either:

    * the `Ezagent.Credential.UserDefaultSource` schema module, or
    * the raw `user_default_credential_sources` table name

  and asserts the ONLY such write-site is the authorized Behavior. It additionally
  asserts the core store does NOT export any public writer (only `resolve` / `changeset`
  / `id` / `set_via_dispatch` — the latter dispatches, it does not persist). It mirrors
  `Ezagent.Invariants.SingleSpawnEntryTest`: grep `*.ex` (lib only — test files exempt),
  reject comments/docstrings, and fail loud on any unexpected write-site so "I'll just
  insert a default source directly for my new feature" drift is impossible without a
  conscious test edit.
  """
  use ExUnit.Case, async: true

  alias Ezagent.Credential.{UserDefaultSource, WorkspaceSharedSource}

  # The cap-checked Behavior is the SOLE module allowed to persist the pointer.
  @allowed_paths [
    "apps/ezagent_domain_identity/lib/ezagent/behavior/user_default_credential_source.ex"
  ]

  @workspace_shared_allowed_paths [
    "apps/ezagent_domain_identity/lib/ezagent/behavior/workspace_shared_credential_source.ex"
  ]

  # Mutating Repo ops. (`set_via_dispatch` is a dispatch helper, not a write; `resolve`
  # uses `Repo.get`, a read.) We only care about table/schema MUTATION.
  @mutating_ops ~w(Repo.insert Repo.insert! Repo.update Repo.update! Repo.delete Repo.delete! Repo.insert_all Repo.update_all Repo.delete_all)

  test "the user_default_credential_sources table/schema is written ONLY by the cap-checked Behavior" do
    apps_root = apps_root()

    # Lines that mention the schema module OR the raw table name.
    {target_lines, grep_exit} =
      System.cmd(
        "grep",
        [
          "-rEn",
          "UserDefaultSource|user_default_credential_sources",
          apps_root,
          "--include=*.ex"
        ],
        stderr_to_stdout: false
      )

    if grep_exit > 1, do: raise("grep scan failed (exit #{grep_exit}) for #{apps_root}")

    # A "write-site" line is one that BOTH references this table/schema AND contains a
    # mutating Repo op on the same line — i.e. a direct persist. (The validate-and-
    # persist body pipes the changeset into `Repo.insert`; the schema is named on the
    # changeset-build line and the `Repo.insert` follows in the pipe, so we also scan
    # for any mutating Repo op inside files that reference the schema — see below.)
    schema_referencing_files =
      target_lines
      |> String.split("\n", trim: true)
      |> Enum.map(&line_path/1)
      |> Enum.uniq()
      |> Enum.reject(&is_nil/1)
      |> Enum.reject(&String.contains?(&1, "/test/"))

    violations =
      for file <- schema_referencing_files,
          {:ok, body} = File.read(file),
          line <- write_op_lines(body),
          not allowed_file?(file, @allowed_paths),
          not comment_line?(line) do
        Path.relative_to(file, String.trim_trailing(apps_root, "/apps")) <> ": " <> line
      end

    assert violations == [],
           """
           Direct mutating Repo write found in a module that references the
           user_default_credential_sources table/schema, OUTSIDE the authorized
           chokepoint:

           #{Enum.join(violations, "\n")}

           The user default-source pointer MUST be persisted ONLY by the cap-checked +
           audited Behavior `Ezagent.ActionSet.UserDefaultCredentialSource`
           (:set_default_credential_source). A direct Repo.insert/update/delete here
           bypasses the cap-check + the {:emit, ...} audit. If you need to set the
           pointer, dispatch the action (see `UserDefaultSource.set_via_dispatch/3`).
           """
  end

  test "the core store exports NO public writer (only read + pure changeset + dispatch helper)" do
    exports = UserDefaultSource.__info__(:functions)

    # `changeset/2` is a PURE builder (no Repo write); `set_via_dispatch/3` dispatches
    # (no Repo write); `resolve/3` + `id/3` are reads/helpers. Anything that smells like
    # a persisting setter must NOT exist on this module.
    forbidden =
      for {name, _arity} <- exports,
          n = Atom.to_string(name),
          n =~ ~r/^(set|persist|insert|update|upsert|delete|put|write|save|store)/,
          name != :set_via_dispatch do
        name
      end

    assert forbidden == [],
           """
           The core store `Ezagent.Credential.UserDefaultSource` exports a function that
           looks like a writer: #{inspect(forbidden)}.

           Core must hold NO cap-less mutator (codex H2). Allowed surface: schema struct,
           `resolve/3` (read), `changeset/2` (pure builder), `id/3` (key helper),
           `set_via_dispatch/3` (dispatch helper — does not persist). Persistence lives in
           the cap-checked Behavior only.
           """

    # Positive assertion: the read + pure-builder surface is present.
    assert function_exported?(UserDefaultSource, :resolve, 3)
    assert function_exported?(UserDefaultSource, :changeset, 2)
    refute function_exported?(UserDefaultSource, :persist_validated, 5)
  end

  test "the workspace_shared_credential_sources table/schema is written ONLY by the cap-checked Behavior" do
    apps_root = apps_root()

    {target_lines, grep_exit} =
      System.cmd(
        "grep",
        [
          "-rEn",
          "WorkspaceSharedSource|workspace_shared_credential_sources",
          apps_root,
          "--include=*.ex"
        ],
        stderr_to_stdout: false
      )

    if grep_exit > 1, do: raise("grep scan failed (exit #{grep_exit}) for #{apps_root}")

    schema_referencing_files =
      target_lines
      |> String.split("\n", trim: true)
      |> Enum.map(&line_path/1)
      |> Enum.uniq()
      |> Enum.reject(&is_nil/1)
      |> Enum.reject(&String.contains?(&1, "/test/"))

    violations =
      for file <- schema_referencing_files,
          {:ok, body} = File.read(file),
          line <- write_op_lines(body),
          not allowed_file?(file, @workspace_shared_allowed_paths),
          not comment_line?(line) do
        Path.relative_to(file, String.trim_trailing(apps_root, "/apps")) <> ": " <> line
      end

    assert violations == [],
           """
           Direct mutating Repo write found in a module that references the
           workspace_shared_credential_sources table/schema, OUTSIDE the authorized
           chokepoint:

           #{Enum.join(violations, "\n")}

           The workspace-shared source pointer MUST be persisted ONLY by the
           cap-checked + audited Behavior
           `Ezagent.ActionSet.WorkspaceSharedCredentialSource`
           (:set_workspace_shared_credential_source). A direct Repo.insert/update/delete
           here bypasses the workspace-admin cap-check and audit effect.
           """
  end

  test "the workspace-shared core store exports NO public writer" do
    exports = WorkspaceSharedSource.__info__(:functions)

    forbidden =
      for {name, _arity} <- exports,
          n = Atom.to_string(name),
          n =~ ~r/^(set|persist|insert|update|upsert|delete|put|write|save|store)/ do
        name
      end

    assert forbidden == [],
           """
           The core store `Ezagent.Credential.WorkspaceSharedSource` exports a function
           that looks like a writer: #{inspect(forbidden)}.

           Core must hold NO cap-less mutator. Allowed surface: schema struct,
           `resolve/2` / `get/2` (reads), `changeset/1` (pure builder), and `id/2`
           (key helper). Persistence lives in the cap-checked workspace Behavior only.
           """

    assert function_exported?(WorkspaceSharedSource, :resolve, 2)
    assert function_exported?(WorkspaceSharedSource, :get, 2)
    assert function_exported?(WorkspaceSharedSource, :changeset, 1)
    refute function_exported?(WorkspaceSharedSource, :persist_validated, 4)
  end

  # ---------------------------------------------------------------------------

  defp write_op_lines(body) do
    body
    |> String.split("\n")
    |> Enum.filter(&actual_write_call?/1)
  end

  # A real write-site is `Repo.insert(...` / `|> Repo.insert(` etc. — the op immediately
  # followed by `(` or `!(`. We also reject any line where the op appears inside backticks
  # (a prose reference inside a `@moduledoc`/`@doc` heredoc) so docstrings don't trip the
  # gate (mirrors SingleSpawnEntryTest's prose-reference guard).
  defp actual_write_call?(line) do
    Enum.any?(@mutating_ops, fn op ->
      String.contains?(line, op <> "(") and not prose_reference?(line, op)
    end)
  end

  defp prose_reference?(line, op) do
    case String.split(line, op, parts: 2) do
      [prefix, _suffix] -> String.contains?(prefix, "`")
      _ -> false
    end
  end

  defp apps_root do
    out =
      case System.cmd("git", ["rev-parse", "--show-toplevel"], stderr_to_stdout: false) do
        {top, 0} ->
          top

        _ ->
          cwd = File.cwd!()
          if File.dir?(Path.join(cwd, "apps")), do: cwd, else: Path.expand("../..", cwd)
      end

    Path.join(String.trim(out), "apps")
  end

  defp line_path(line) do
    case String.split(line, ":", parts: 2) do
      [path, _rest] -> path
      _ -> nil
    end
  end

  defp allowed_file?(file, allowed_paths) do
    Enum.any?(allowed_paths, &String.contains?(file, &1))
  end

  defp comment_line?(line) do
    String.starts_with?(String.trim_leading(line), "#")
  end
end
