defmodule Ezagent.Invariants.UserDefaultSourceSingleWriterTest do
  @moduledoc """
  #17 cascade PR-0 (spec §5.2, codex H2) — structural single-writer invariant for the
  user default credential-source pointer.

  `Ezagent.Credential.UserDefaultSource.persist_validated/5` is the action BODY
  (validate + persist, NO auth). The ONLY authorized write path is the cap-checked +
  audited Behavior dispatch (`Ezagent.Behavior.UserDefaultCredentialSource`). If any
  other lib module could call `persist_validated` directly, an in-VM caller would bypass
  the cap-check + audit — exactly the public cap-less writer codex flagged.

  This gate asserts that the ONLY lib call-site of `persist_validated` is that Behavior
  (plus the store module itself, where the function is defined). It mirrors
  `Ezagent.Invariants.SingleSpawnEntryTest`: grep `*.ex` (lib only — test files are
  exempt, they exercise the validation body in isolation), reject comments/docstrings,
  and fail loud on any unexpected call-site so "I'll just call persist_validated
  directly for my new feature" drift is impossible without a conscious test edit.
  """
  use ExUnit.Case, async: true

  # The store module DEFINES the function; the Behavior is the SOLE caller.
  @allowed_paths [
    "apps/ezagent_core/lib/ezagent/credential/user_default_source.ex",
    "apps/ezagent_domain_identity/lib/ezagent/behavior/user_default_credential_source.ex"
  ]

  test "persist_validated/5 is called only from the UserDefaultCredentialSource Behavior" do
    apps_root = apps_root()

    {output, grep_exit} =
      System.cmd(
        "grep",
        ["-rEn", "persist_validated", apps_root, "--include=*.ex"],
        stderr_to_stdout: false
      )

    # grep exit 0 = matches, 1 = clean (no matches); ≥2 = scan error. Fail loud rather
    # than silently passing the gate on an empty result.
    if grep_exit > 1, do: raise("grep scan failed (exit #{grep_exit}) for #{apps_root}")

    violations =
      output
      |> String.split("\n", trim: true)
      |> Enum.reject(&allowed_path?/1)
      |> Enum.reject(&comment_or_docstring?/1)

    assert violations == [],
           """
           `persist_validated` called outside the authorized chokepoint:

           #{Enum.join(violations, "\n")}

           The user default-source pointer MUST be written ONLY through the cap-checked
           dispatch `Ezagent.Behavior.UserDefaultCredentialSource`
           (:set_default_credential_source). Calling `persist_validated/5` directly
           bypasses the cap-check + audit. If you need to set the pointer, dispatch the
           action (see `UserDefaultSource.set_via_dispatch/3`).
           """
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

  defp allowed_path?(line) do
    Enum.any?(@allowed_paths, &String.contains?(line, &1))
  end

  # Lines where `persist_validated` appears as TEXT inside a `#` comment or a
  # `@moduledoc`/`@doc` heredoc — not a real call. Conservative heuristic (mirrors
  # SingleSpawnEntryTest): trimmed body starts with `#`, or the substring before the
  # token contains a backtick / arrow (prose reference inside a doc heredoc).
  defp comment_or_docstring?(line) do
    case String.split(line, ":", parts: 3) do
      [_path, _lineno, body] ->
        trimmed = String.trim_leading(body)

        cond do
          String.starts_with?(trimmed, "#") -> true
          prose_reference?(body) -> true
          true -> false
        end

      _ ->
        false
    end
  end

  defp prose_reference?(body) do
    case String.split(body, "persist_validated", parts: 2) do
      [prefix, _suffix] -> String.contains?(prefix, "`") or String.contains?(prefix, "→")
      _ -> false
    end
  end
end
