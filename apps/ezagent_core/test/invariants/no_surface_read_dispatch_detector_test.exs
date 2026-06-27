defmodule EzagentCore.Invariants.NoSurfaceReadDispatchDetectorTest do
  @moduledoc """
  SPEC §8.11 (positive control) + §8.12 (negative carve-outs) for the
  `no_surface_read_dispatch` gate's DETECTORS — kept DISTINCT from the
  regression-lock (`NoSurfaceReadDispatchTest`): that test proves the tree is
  clean AFTER migration; this one proves the detectors actually DETECT (and don't
  over-match), independent of migration state. Without this, a broken regex would
  let the regression-lock pass vacuously.

  Tests run the actual probe patterns (read via the shared
  `NoSurfaceReadDispatchProbes` support module — single source of truth) against
  synthetic fixture strings — no source tree, no BEAM.
  """

  use ExUnit.Case, async: true

  alias EzagentCore.Invariants.NoSurfaceReadDispatchProbes, as: Probes

  defp probe(id), do: Enum.find(Probes.probes(), &(&1.id == id))
  defp p14, do: probe(:p14).pattern
  defp p15, do: probe(:p15).pattern

  # ── §8.11 positive control — the detectors are NOT vacuous ─────────

  test "p14 MATCHES the raw-dispatch recurrence forms (caps + sandbox)" do
    assert Regex.match?(p14(), ~s|with_action(uri, :sandbox, :read)|)
    assert Regex.match?(p14(), ~s|with_action(uri, :identity, :list_caps)|)

    assert Regex.match?(
             p14(),
             ~s|Invocation.dispatch(with_action(agent_uri, :sandbox, :read), ctx)|
           )
  end

  test "p15 MATCHES the dispatching read-facade call (fully-qualified AND bare-alias)" do
    assert Regex.match?(p15(), ~s|Ezagent.Agent.Config.read_cascade(agent_uri, caller, caps)|)
    # the bare-alias form codex showed p14 alone (and a fully-qualified-only p15) would miss.
    assert Regex.match?(p15(), ~s|Config.read_cascade(agent_uri, caller, caps)|)
  end

  # ── §8.12 negative carve-outs — the detectors do NOT over-match ────

  test "(a) the live PTY-buffer read (direct call, no read-class action) is NOT matched" do
    pty_buffer = ~s|Ezagent.Domain.Pty.Server.snapshot_buffer(agent_uri)|
    pty_initial = ~s|World.IdentityData.pty_initial_buffer(agent_uri)|

    refute Regex.match?(p14(), pty_buffer)
    refute Regex.match?(p15(), pty_buffer)
    refute Regex.match?(p14(), pty_initial)
    refute Regex.match?(p15(), pty_initial)
  end

  test "(b) the :list_api_keys surface dispatch (sensitive, carve-out B) is NOT matched" do
    list_api_keys = ~s|with_action(agent_uri, :identity, :list_api_keys)|

    refute Regex.match?(p14(), list_api_keys),
           "p14 keys on :list_caps, not :list_* — :list_api_keys must stay dispatchable (§5/§11.2 B)"

    refute Regex.match?(p15(), list_api_keys)
  end

  test "(c) a WRITE dispatch (with_action(uri, :pty, :write)) is NOT matched" do
    pty_write = ~s|with_action(uri, :pty, :write)|
    session_send = ~s|with_action(uri, :session, :send)|
    put_api_key = ~s|with_action(uri, :identity, :put_api_key)|

    for write <- [pty_write, session_send, put_api_key] do
      refute Regex.match?(p14(), write), "WRITE dispatch must not be forbidden: #{write}"
      refute Regex.match?(p15(), write)
    end
  end

  test "(d) config MUTATION facade calls (apply_delta / delete_path / repoint) are NOT matched by p15" do
    # p15 keys on read_cascade ONLY; the write facades legitimately dispatch.
    mutations = [
      ~s|Ezagent.Agent.Config.apply_delta(agent_uri, delta, caller, caps)|,
      ~s|Agent.Config.delete_path(agent_uri, path, caller, caps)|,
      ~s|Agent.Config.repoint(agent_uri, key, caller, caps)|
    ]

    for mutation <- mutations do
      refute Regex.match?(p15(), mutation),
             "config WRITE facade must not be forbidden: #{mutation}"

      refute Regex.match?(p14(), mutation)
    end
  end

  # ── the sanctioned reader path is NOT flagged ─────────────────────

  test "the unified Domain.Agent.read_* calls (the sanctioned replacement) are NOT matched" do
    for call <- [
          ~s|Ezagent.Domain.Agent.read_config(agent_uri, ctx)|,
          ~s|Ezagent.Domain.Agent.read_caps(entity_uri, ctx)|,
          ~s|Ezagent.Domain.Agent.read_sandbox(agent_uri, ctx)|
        ] do
      refute Regex.match?(p14(), call)
      refute Regex.match?(p15(), call)
    end
  end
end
