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
  `Ezagent.Domain.Python.Server`, plugin per-app `DynamicSupervisor`
  declarations in `Application` child lists) are exempt — they're not
  Kinds and have their own supervision concerns. The exemption table is
  `allowed_sidecar_paths/0` below; adding a new sidecar requires
  appending its path AND updating the moduledoc rationale.

  ## Domain.Python (added 2026-05-23, np-agent plugin PR)

  Domain.Python's facade (`apps/ezagent_domain_python/lib/ezagent/
  domain/python.ex`) calls `DynamicSupervisor.start_child` to spawn
  `Ezagent.Domain.Python.Server` — the uv-launched Python subprocess
  wrapper. Server is a sidecar (not a Kind), managed by plugin
  Template Classes (np.agent today; other Python-backed flavors
  later). Mirror of the Domain.Pty exemption.

  ## ExternalMirror.WorkerSpawn (added 2026-05-25, PR-EM-2)

  `Ezagent.ExternalMirror.WorkerSpawn.spawn/4` calls
  `DynamicSupervisor.start_child(RootSupervisor, per_binding_sup_spec)`
  to start a `PerBindingSupervisor` — NOT a Kind process directly. The
  PerBindingSupervisor in turn starts the actual `Kind.Server` via its
  own `Supervisor.init/1` children list, preserving the
  "Kind.Server lives behind a sup boundary" topology mandated by
  SPEC `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`
  §6.3 (r4 HIGH-2 two-tier fix).

  This file (`worker_spawn.ex`) is the spawn-side bridge that the new
  `Kind.spawn_strategy/0` callback on `Ezagent.Entity.ExternalMirrorWorker`
  routes through. `Kind.spawn(ExternalMirrorWorker, params)` still
  exists as the SOLE Kind-spawn entry — it just delegates the
  child-spec shape to this Domain helper because the two-tier
  topology is Domain-specific and doesn't belong in core.
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
      "apps/ezagent_domain_pty/lib/ezagent/domain/pty.ex",
      # Ezagent.Domain.Python.start_subprocess/1 is the facade over
      # the Domain.Python supervision tree (Domain.Python SPEC
      # 2026-05-23 §1.1, merged #256). The Server it starts is a
      # sidecar managed by plugin Template Classes (np.agent today;
      # other Python-backed flavors later) — NOT a Kind. The
      # `child_spec/1` heredoc in server.ex is matched too (line 62 in
      # the @doc string referencing DynamicSupervisor.start_child/2 as
      # PROSE); the comment_or_docstring? heuristic catches the
      # backtick-quoted reference, but the line lacks a backtick BEFORE
      # the call name and was caught — exempting the file path is the
      # safe + intentional fix (the server has exactly one start_link
      # callsite, no real DynamicSupervisor.start_child call).
      "apps/ezagent_domain_python/lib/ezagent/domain/python.ex",
      "apps/ezagent_domain_python/lib/ezagent/domain/python/server.ex",
      # Ezagent.ExternalMirror.WorkerSpawn (2026-05-25, PR-EM-2 / SPEC
      # `docs/superpowers/specs/2026-05-24-external-mirror-domain.md`
      # §6.3) — Kind.spawn(ExternalMirrorWorker, _) delegates here via
      # the new `spawn_strategy/0` callback. The `start_child` call
      # below spawns a `PerBindingSupervisor` (NOT a Kind directly);
      # the PerBindingSupervisor's init/1 starts the Kind.Server child
      # through `Supervisor.init/1` (not start_child). Two-tier
      # topology preserved.
      "apps/ezagent_domain_external_mirror/lib/ezagent/external_mirror/worker_spawn.ex"
    ]
  end
end
