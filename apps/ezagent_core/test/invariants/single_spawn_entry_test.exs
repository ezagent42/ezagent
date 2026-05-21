defmodule Ezagent.Invariants.SingleSpawnEntryTest do
  @moduledoc """
  Asserts no lib code calls `DynamicSupervisor.start_child` for a Kind
  process outside `Ezagent.Kind.spawn/2`. The only call-site of
  `DynamicSupervisor.start_child` for a Kind wrapper lives inside
  `Ezagent.Kind` itself (which IS the API).

  Per V1 prevention layer 5 (Allen 2026-05-21): structural
  enforcement that all Kind spawning goes through one chokepoint, so
  future "I'll just call start_child directly for my new plugin's
  Kind" drift is impossible without conscious test edits.

  Sidecar / infrastructure processes (e.g., `Ezagent.Domain.Pty.Server`,
  plugin per-app `DynamicSupervisor` declarations in `Application`
  child lists) are exempt — they're not Kinds and have their own
  supervision concerns. The exemption table is
  `allowed_sidecar_paths/0` below; adding a new sidecar requires
  appending its path AND updating the moduledoc rationale.
  """
  use ExUnit.Case, async: true

  test "no direct DynamicSupervisor.start_child for Kind processes in lib code" do
    apps_root = apps_root()

    {output, _exit_code} =
      System.cmd(
        "grep",
        [
          "-rEn",
          "DynamicSupervisor\\.start_child",
          apps_root,
          "--include=*.ex"
        ],
        stderr_to_stdout: true
      )

    violations =
      output
      |> String.split("\n", trim: true)
      |> Enum.reject(&kind_module_self?/1)
      |> Enum.reject(&comment_or_docstring?/1)
      |> Enum.reject(&allowed_sidecar?/1)

    assert violations == [],
           """
           Direct DynamicSupervisor.start_child found outside Ezagent.Kind.spawn/2:

           #{Enum.join(violations, "\n")}

           Kind processes MUST be spawned via Ezagent.Kind.spawn(KindModule, params).
           Sidecar/infrastructure processes (PtyServer, plugin per-app DynamicSupervisors)
           are exempt — add their path to allowed_sidecar_paths/0 in this test
           AND document the rationale in the moduledoc if you're adding a new one.
           """
  end

  defp apps_root do
    {out, 0} = System.cmd("git", ["rev-parse", "--show-toplevel"])
    Path.join(String.trim(out), "apps")
  end

  # `apps/ezagent_core/lib/ezagent/kind.ex` IS the API — the one allowed
  # `DynamicSupervisor.start_child` call lives in `Ezagent.Kind.spawn/2`.
  defp kind_module_self?(line) do
    String.contains?(line, "apps/ezagent_core/lib/ezagent/kind.ex:")
  end

  # Lines where `DynamicSupervisor.start_child` appears as TEXT — inside
  # a `#` comment, a `@moduledoc` / `@doc` heredoc body, or quoted in
  # backticks for prose — not as a real call site.
  #
  # Heuristics (all conservative — a false negative here just means a
  # real bug squeaks past the gate; a false positive lets a violation
  # through, which the runtime invariant test catches):
  #
  # 1. Trimmed body starts with `#` → comment.
  # 2. Substring before `DynamicSupervisor` contains backtick or `→` →
  #    prose reference inside a doc heredoc.
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
    case String.split(body, "DynamicSupervisor.start_child", parts: 2) do
      [prefix, _suffix] ->
        String.contains?(prefix, "`") or String.contains?(prefix, "→")

      _ ->
        false
    end
  end

  defp allowed_sidecar?(line) do
    Enum.any?(allowed_sidecar_paths(), &String.contains?(line, &1))
  end

  # Sidecar / infrastructure exemptions — these spawn NON-Kind
  # processes. Adding a new sidecar requires appending here AND
  # updating the moduledoc.
  defp allowed_sidecar_paths do
    [
      # Ezagent.Domain.Pty.start/2 is the facade over the Domain.Pty
      # supervision tree (Domain.Pty PR-A 2026-05-21 SPEC v1 §3.1).
      # The Server it starts is a sidecar managed by per-flavor
      # Templates (cc.agent today; echo-with-pty / future plugins
      # later) — NOT a Kind. Pre-PR-A this exemption pointed at
      # cc_agent.ex's inline DynamicSupervisor.start_child; the PR
      # collapsed all start_child callsites for PtyServer down to this
      # one facade.
      "apps/ezagent_domain_pty/lib/ezagent/domain/pty.ex"
    ]
  end
end
