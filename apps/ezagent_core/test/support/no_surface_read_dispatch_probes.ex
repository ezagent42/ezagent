defmodule EzagentCore.Invariants.NoSurfaceReadDispatchProbes do
  @moduledoc """
  Single source of truth for the `no_surface_read_dispatch` gate probes (SPEC
  `unified-non-activating-agent-read.md` §11). A `test/support` module (compiled
  in test env) so BOTH the regression-lock (`NoSurfaceReadDispatchTest`) and the
  detector positive-control/carve-out test (`NoSurfaceReadDispatchDetectorTest`)
  reference the SAME `%{id, desc, pattern, allowlist}` definitions — a test
  module cannot reliably reference another test module's functions (ExUnit loads
  them independently / in parallel partitions), so the shared shape lives here.
  """

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
      allowlist: []
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
      allowlist: []
    }
  ]

  @doc "The probe definitions (`%{id, desc, pattern, allowlist, surface_only}`)."
  def probes, do: @probes

  @doc "The surface-dir globs scanned by `surface_only: true` probes."
  def surface_globs, do: @surface_globs
end
