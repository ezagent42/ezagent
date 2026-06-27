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

  # Surface dirs scanned by `surface_only: true` probes (SPEC §11.1 / OQ-7).
  @surface_globs [
    "apps/ezagent_plugin_world/lib/**/*.ex",
    "apps/ezagent_web/lib/**/*.ex",
    # operator CLI / "console" — WRITES allowed, the 3 reads not.
    "apps/*/lib/mix/tasks/*.ex"
  ]

  @probes [
    # p14 — FORM (i): surface dispatches a read-class action atom via with_action/3.
    # Covers caps (:identity/:list_caps) and sandbox (:sandbox/:read). Config is
    # NOT here — it is form (ii), p15.
    %{
      id: :p14,
      desc:
        "surface/presentation layer dispatching a CONSOLIDATED READ-class action to an agent " <>
          "(re-introducing activate-on-read). Agent caps/sandbox reads MUST go through " <>
          "Ezagent.Domain.Agent.read_* (non-activating). Forbidden pairs: " <>
          "(:identity,:list_caps) (:sandbox,:read). WRITE/action dispatch is NOT forbidden " <>
          "(it legitimately activates); the live PTY-buffer read is a direct call, not a " <>
          "dispatch, and is NOT covered. Config is covered by p15 (facade form). See SPEC §11.",
      pattern:
        ~r/with_action\([^,]+,\s*:identity,\s*:list_caps\)|with_action\([^,]+,\s*:sandbox,\s*:read\)/,
      surface_only: true,
      allowlist: ["apps/ezagent_domain_session/lib/ezagent/domain/agent.ex"]
    },

    # p15 — FORM (ii): surface calls the dispatching READ FACADE directly. The
    # facade builds `?action=config_evolve.read_cascade` internally, so form (i)
    # never sees it. After migration the only sanctioned surface config-read path
    # is Domain.Agent.read_config/3.
    %{
      id: :p15,
      desc:
        "surface/presentation layer calling the DISPATCHING read facade " <>
          "`Ezagent.Agent.Config.read_cascade(` directly (it dispatches " <>
          "?action=config_evolve.read_cascade internally → activates a cold agent). Surface " <>
          "config reads MUST go through Ezagent.Domain.Agent.read_config/3 (non-activating). " <>
          "See SPEC §11.",
      pattern: ~r/(?:Ezagent\.)?Agent\.Config\.read_cascade\(|(?<![.\w])Config\.read_cascade\(/,
      surface_only: true,
      allowlist: ["apps/ezagent_domain_session/lib/ezagent/domain/agent.ex"]
    }
  ]

  @doc false
  def probes, do: @probes

  test "no surface re-introduces an activate-on-read (p14 raw dispatch + p15 facade call)" do
    umbrella_root = umbrella_root()

    offenders =
      for probe <- @probes,
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
    @surface_globs
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
