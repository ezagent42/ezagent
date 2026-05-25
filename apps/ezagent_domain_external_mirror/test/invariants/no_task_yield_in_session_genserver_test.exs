defmodule Ezagent.ExternalMirror.Invariants.NoTaskYieldInSessionGenServerTest do
  @moduledoc """
  PR-EM-FINAL invariant 10.

  SPEC `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`
  §8.2 r6 HIGH-2: the bind facade's `target_ownership_check/2`
  Task lives in the CALLER PROCESS, not the Session Kind GenServer.
  Putting `Task.yield/2` (or `Task.await/2`) inside a Session-side
  callback would block the Session GenServer for the full 5-second
  timeout window — chat sends, subscribe calls, and other binds on
  the same session would all queue behind it.

  This grep gate enforces the structural rule: the Session GenServer
  module (`apps/ezagent_domain_chat/lib/ezagent/entity/session.ex`)
  and any Behavior module registered against the Session Kind under
  the ExternalMirror Domain MUST NOT call `Task.yield/2` or
  `Task.await/2`. The async-with-timeout pattern lives ONLY in the
  facade module (`Ezagent.ExternalMirror.bind/4`).

  ## Why grep, not behavioral test

  A behavioral test ("Session GenServer doesn't block during bind")
  already exists in
  `apps/ezagent_domain_external_mirror/test/ezagent/behavior/external_mirror_test.exs`
  ("PR-EM-3 (k) Session GenServer not blocked during target check").
  That test catches the runtime symptom. THIS grep gate catches the
  STRUCTURE — the pattern that would re-introduce the regression —
  so a refactor that moves Task.yield into the Session GenServer
  fails at the same test step a runtime regression would, with a
  clearer error pointing at the introduced line.

  ## Scope

  Greps:
  - `apps/ezagent_domain_chat/lib/ezagent/entity/session.ex` —
    the Session GenServer.
  - `apps/ezagent_domain_external_mirror/lib/ezagent/behavior/external_mirror.ex` —
    the Behavior registered against the Session Kind.
  - `apps/ezagent_domain_external_mirror/lib/ezagent/behavior/external_mirror_worker.ex` —
    the Worker Behavior (NOT the Session, but the same anti-pattern
    would block per-binding Workers).

  Does NOT grep `Ezagent.ExternalMirror` (the facade) — that's
  exactly where `Task.yield` belongs.
  """
  use ExUnit.Case, async: true

  @forbidden_patterns [
    "Task\\.yield\\(",
    "Task\\.await\\("
  ]

  @scoped_paths [
    "ezagent_domain_chat/lib/ezagent/entity/session.ex",
    "ezagent_domain_external_mirror/lib/ezagent/behavior/external_mirror.ex",
    "ezagent_domain_external_mirror/lib/ezagent/behavior/external_mirror_worker.ex"
  ]

  test "no Task.yield / Task.await inside the Session GenServer or its registered ExternalMirror Behaviors" do
    violations =
      for path <- @scoped_paths, pattern <- @forbidden_patterns do
        full_path = Path.join(apps_root(), path)
        grep_one(full_path, pattern)
      end
      |> List.flatten()

    assert violations == [],
           """
           Task.yield/Task.await inside Session-side callback — violates
           PR-EM-FINAL invariant 10.

           These blocking primitives belong ONLY in the facade module
           (`Ezagent.ExternalMirror`), which runs in the CALLER PROCESS.
           Inside the Session GenServer or Worker Kind callbacks, they
           would block the per-Kind scheduler quantum for the full timeout
           (up to 5s by default) — chat sends, subscribe calls, and
           other binds queue behind it.

           If the new callsite is in a `Task.Supervisor.async_nolink/3` +
           `Task.yield/2` pair, MOVE the pair to the facade and propagate
           the result via dispatch args. See `Ezagent.ExternalMirror.bind/4`
           for the canonical shape (SPEC §8.2 r6 HIGH-2).

           Offenders:
           #{Enum.join(violations, "\n")}
           """
  end

  defp grep_one(path, pattern) do
    case File.exists?(path) do
      false ->
        []

      true ->
        {output, _exit} =
          System.cmd(
            "grep",
            ["-En", pattern, path],
            stderr_to_stdout: true
          )

        output
        |> String.split("\n", trim: true)
        # `grep -n path: ...` form on a single file — re-prefix with the
        # full path so the violation report carries the file location.
        |> Enum.map(fn line -> "#{path}:#{line}" end)
        |> Enum.reject(&comment_or_docstring?/1)
    end
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
    cond do
      String.contains?(body, "`Task.yield") -> true
      String.contains?(body, "`Task.await") -> true
      true -> false
    end
  end

  defp apps_root do
    {out, 0} = System.cmd("git", ["rev-parse", "--show-toplevel"])
    Path.join(String.trim(out), "apps")
  end
end
