defmodule Ezagent.ExternalMirror.Invariants.NoStringToAtomOnUserInputTest do
  @moduledoc """
  PR-EM-FINAL invariant 8.

  Atomization of caller-controlled strings is the classic
  unbounded-atom-table DOS. The ExternalMirror Domain accepts caller
  data (`adapter_id`, `target_id`, `opts`) and persists it; any
  `String.to_atom/1` (or `Map.new(_, fn _ -> {String.to_atom(...), _})`)
  on that surface is a vector.

  ## Allowed callsites

  The Domain MAY use `String.to_atom/1` on inputs that are bounded by
  plugin-compile-time data (e.g. `adapter_id` returned by
  `adapter_module.adapter_id/0` — the set is fixed at deploy time,
  one atom per registered adapter). Each such allowed callsite MUST
  appear in `allowed_call_sites/0` below AND carry a moduledoc / inline
  comment explaining why the input is bounded.

  Adding a new allowed callsite requires:
  - the value MUST originate from plugin module code, NOT from a
    dispatch arg map or external HTTP payload
  - the path goes in `allowed_call_sites/0` with a one-line rationale

  ## Why this is structural, not stylistic

  Pre-fix history: PR-EM-3 round-1 had
  `String.to_atom(opts.adapter_id)` inside the `:bind` action body —
  a caller could trigger unbounded atom creation by spamming bind
  attempts with new `adapter_id` strings. Codex caught it; this gate
  prevents the regression class.
  """
  use ExUnit.Case, async: true

  @pattern "String\\.to_atom"

  test "no String.to_atom callsites in apps/ezagent_domain_external_mirror/lib/ outside the allowlist" do
    domain_lib = Path.join(apps_root(), "ezagent_domain_external_mirror/lib")

    {output, _exit} =
      System.cmd(
        "grep",
        ["-rEn", @pattern, domain_lib, "--include=*.ex"],
        stderr_to_stdout: true
      )

    violations =
      output
      |> String.split("\n", trim: true)
      |> Enum.reject(&comment_or_docstring?/1)
      |> Enum.reject(&allowed?/1)

    assert violations == [],
           """
           Unbounded `String.to_atom/1` callsite(s) in ExternalMirror
           Domain — violates PR-EM-FINAL invariant 8.

           Atom-table memory is never reclaimed; converting caller-
           controlled strings to atoms is the classic BEAM DOS. If the
           input is bounded by plugin-compile-time data (e.g. the set
           of registered adapter_ids), add the file path to
           `allowed_call_sites/0` in this test AND document why.

           Offenders:
           #{Enum.join(violations, "\n")}
           """
  end

  # Each entry is `{path_substring, rationale}`. The path match is a
  # substring on the full grep line (which starts with the absolute
  # file path), so a partial path uniquely identifies the file.
  defp allowed_call_sites do
    [
      {
        "ezagent_domain_external_mirror/lib/ezagent/external_mirror/adapter_install.ex",
        # The `String.to_atom("allow_" <> adapter_id)` callsite. The
        # adapter_id originates from `adapter_module.adapter_id/0` —
        # plugin module code, fixed at deploy time. Bounded by the
        # number of registered adapter modules. See AdapterInstall
        # moduledoc + the inline comment at the callsite.
        "bounded by adapter_id which is plugin-compile-time fixed"
      }
    ]
  end

  defp allowed?(line) do
    Enum.any?(allowed_call_sites(), fn {path_substring, _rationale} ->
      String.contains?(line, path_substring)
    end)
  end

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
    case String.split(body, "String.to_atom", parts: 2) do
      [prefix, _] ->
        String.contains?(prefix, "`") or String.contains?(prefix, "→")

      _ ->
        false
    end
  end

  defp apps_root do
    {out, 0} = System.cmd("git", ["rev-parse", "--show-toplevel"])
    Path.join(String.trim(out), "apps")
  end
end
