defmodule EzagentCore.Invariants.NoSurfaceReadDispatchTest do
  @moduledoc """
  Anti-recurrence arch-gate `no_surface_read_dispatch` — SPEC
  `unified-non-activating-agent-read.md` §11.

  Mirrors the proven `CapCheckOnlyAtChokepointTest` probe machinery (same
  `%{id, desc, pattern, allowlist}` shape, source-tree scan, no runtime BEAM)
  but owns its OWN moduledoc + assertion message (a read-dispatch violation is
  NOT a cap-check-shape leak, so it must not borrow the "G2 leakage" message).

  It FORBIDS the presentation/surface layer (world / web / operator-CLI) from
  reading an agent's config / caps / sandbox by an ACTIVATING path — the FP5/#115
  activate-on-read bug. Two probes cover the two syntactic forms a surface read
  takes:

    * p14 — FORM (i): a raw `with_action(uri, <behavior>, <action>)` dispatch of
      the consolidated read pairs `(:identity, :list_caps)` / `(:sandbox, :read)`.
    * p15 — FORM (ii): a direct call to the dispatching READ FACADE
      `Ezagent.Agent.Config.read_cascade(` (it builds the
      `?action=config_evolve.read_cascade` URI internally, so form (i) never sees
      it at the surface — codex adversarial-review finding §11.5).

  After the §9 migration the ONLY sanctioned surface read path is the
  non-activating `Ezagent.Domain.Agent.read_{config,caps,sandbox,status}`. These
  probes are the regression-lock that keeps the cleaned state cleaned: a future
  surface re-introducing an activate-on-read breaks this gate.

  Scope is the surface dirs ONLY (`surface_only: true`) — WRITE/action dispatch
  legitimately activates and is NOT forbidden; the live PTY-buffer read is a
  direct call (no read-class action atom) and is NOT covered; `:list_api_keys`
  (sensitive, data_owner/admin-gated, §5) stays dispatchable.

  Runs under the same `mix test` / `mix precommit` aggregate as the other
  `EzagentCore.Invariants.*` probe tests (no separate registration). On a new
  surface app, add its `lib/` to `@surface_globs` (SPEC OQ-7).

  See SPEC docs/together/2026-06-26/specs/unified-non-activating-agent-read.md §11.
  """

  use ExUnit.Case, async: true

  alias EzagentCore.Invariants.NoSurfaceReadDispatchProbes, as: Probes

  test "no surface re-introduces an activate-on-read (p14 raw dispatch + p15 facade call)" do
    umbrella_root = umbrella_root()

    offenders =
      for probe <- Probes.probes(),
          path <- files_for(probe, umbrella_root),
          not allowed_path?(path, probe.allowlist),
          content = File.read!(path),
          Regex.match?(probe.pattern, content),
          do:
            "[#{probe.id}] #{probe.desc}\n      @ #{path}\n      pattern: #{inspect(probe.pattern)}"

    assert offenders == [],
           "no_surface_read_dispatch — a presentation/surface layer is reading agent state by " <>
             "a path that ACTIVATES a cold agent (FP5/#115): either dispatching a read-class " <>
             "action (p14) or calling a dispatching read facade (p15). Agent " <>
             "config/caps/sandbox/status reads MUST go through the non-activating " <>
             "Ezagent.Domain.Agent.read_* interface.\n\n" <>
             Enum.join(offenders, "\n\n") <>
             "\n\nReplace with Ezagent.Domain.Agent.read_{config,caps,sandbox}/N " <>
             "(authorize-then-delegate, non-activating). WRITE/action dispatch is fine; live " <>
             "PTY-buffer reads are direct calls, not dispatches, and are unaffected.\n" <>
             "See SPEC docs/together/2026-06-26/specs/unified-non-activating-agent-read.md §11."
  end

  # ── machinery (mirrors CapCheckOnlyAtChokepointTest + surface_only) ──

  defp umbrella_root, do: Path.expand("../../../..", __DIR__)

  # `surface_only: true` probes scan ONLY @surface_globs; others (none here) scan
  # the global `apps/*/lib/**/*.ex` like p1-p13.
  defp files_for(%{surface_only: true}, umbrella_root) do
    Probes.surface_globs()
    |> Enum.flat_map(fn glob -> Path.wildcard(Path.join(umbrella_root, glob)) end)
    |> Enum.uniq()
  end

  defp files_for(_probe, umbrella_root) do
    Path.wildcard(Path.join(umbrella_root, "apps/*/lib/**/*.ex"))
  end

  defp allowed_path?(path, allowlist) do
    Enum.any?(allowlist, fn allowed -> String.contains?(path, allowed) end)
  end
end
