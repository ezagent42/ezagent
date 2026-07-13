defmodule Ezagent.Domain.Pty.SupervisorIsolationTest do
  @moduledoc """
  cc-PTY hardening 2026-07-10 (audit #3) — a single crash-looping PtyServer
  must NOT take down its siblings.

  Before the fix, the PtyServer `DynamicSupervisor` ran with OTP's default
  intensity (3 restarts in 5 s) and no respawn backoff, so one crash-looping
  `claude` exceeded intensity and OTP terminated EVERY child + the supervisor
  — a node-wide PTY wipe. The fix pairs a generous, explicit supervisor
  intensity with a per-child sliding-window respawn backoff that rate-limits a
  looping child well below that ceiling.

  This exercises the real `Ezagent.Domain.Pty.Server` under a private
  `DynamicSupervisor` (so the app-wide supervisor is untouched): a crash-looping
  child runs alongside a stable sibling; the sibling and the supervisor must
  survive. A separate test pins the LIVE app supervisor's intensity so the
  production ceiling can't silently regress to the OTP default.
  """
  use ExUnit.Case, async: false

  alias Ezagent.Domain.Pty.Server, as: PtyServer
  alias Ezagent.Domain.Pty.RespawnBackoff

  # Private-supervisor intensity for the behavioral test. Generous ceiling; the
  # backoff keeps ONE looper far below it. Small `max_seconds` keeps the test
  # fast while still spanning a full intensity window.
  @max_restarts 15
  @max_seconds 2

  # Backoff scaled so a looping child stays ~7 restarts per 2 s window (< 15),
  # but WITHOUT backoff would spin ~100/s and trip the ceiling — making this a
  # genuine regression guard for both the intensity override AND the backoff.
  @backoff_base 60
  @backoff_cap 300
  @backoff_window 2_000

  # 2026-07-13: this test pins the BACKOFF's isolation property — that a child which
  # keeps looping is rate-limited below the supervisor's intensity. The respawn
  # BREAKER (`RespawnPolicy`) would halt that looper after a few failed starts, and
  # there would be no sustained loop left to rate-limit, so it is held off here. The
  # breaker has its own test (`server_respawn_breaker_test.exs`); this one must keep
  # guarding what it was written to guard.
  @breaker_off 10_000

  setup do
    prev = %{
      base: Application.get_env(:ezagent_domain_pty, :respawn_backoff_base_ms),
      cap: Application.get_env(:ezagent_domain_pty, :respawn_backoff_cap_ms),
      window: Application.get_env(:ezagent_domain_pty, :respawn_backoff_window_ms),
      max_failures: Application.get_env(:ezagent_domain_pty, :respawn_max_failures)
    }

    Application.put_env(:ezagent_domain_pty, :respawn_backoff_base_ms, @backoff_base)
    Application.put_env(:ezagent_domain_pty, :respawn_backoff_cap_ms, @backoff_cap)
    Application.put_env(:ezagent_domain_pty, :respawn_backoff_window_ms, @backoff_window)
    Application.put_env(:ezagent_domain_pty, :respawn_max_failures, @breaker_off)

    on_exit(fn ->
      for {v, app_key} <- [
            {prev.base, :respawn_backoff_base_ms},
            {prev.cap, :respawn_backoff_cap_ms},
            {prev.window, :respawn_backoff_window_ms},
            {prev.max_failures, :respawn_max_failures}
          ] do
        case v do
          nil -> Application.delete_env(:ezagent_domain_pty, app_key)
          val -> Application.put_env(:ezagent_domain_pty, app_key, val)
        end
      end
    end)

    :ok
  end

  test "a crash-looping child does not terminate a sibling PtyServer or the supervisor" do
    {:ok, sup} =
      DynamicSupervisor.start_link(
        strategy: :one_for_one,
        max_restarts: @max_restarts,
        max_seconds: @max_seconds
      )

    on_exit(fn -> if Process.alive?(sup), do: Process.exit(sup, :kill) end)

    sibling_uri = fresh_uri("sibling")
    looper_uri = fresh_uri("looper")
    RespawnBackoff.clear(URI.to_string(looper_uri))

    # Sibling: test_mode → never spawns/crashes; a stable canary whose pid must
    # persist for the whole test.
    {:ok, sibling} =
      DynamicSupervisor.start_child(
        sup,
        {PtyServer, %{agent_uri: sibling_uri, cwd: "/tmp", test_mode: true}}
      )

    # Looper: a real spawn of an immediately-exiting command → the child dies at
    # once and the supervisor restarts it, over and over. (Even if erlexec were
    # unavailable, the spawn would fail the same way — still a restart loop the
    # backoff must rate-limit.)
    {:ok, _looper} =
      DynamicSupervisor.start_child(
        sup,
        {PtyServer,
         %{
           agent_uri: looper_uri,
           cwd: "/tmp",
           test_mode: false,
           cmd_override: ["/bin/sh", "-c", "exit 1"]
         }}
      )

    # Watch for ~1.5 intensity windows. If the fix regressed (intensity back to
    # 3-in-5s, or backoff removed), the looper would trip the ceiling and OTP
    # would kill the sibling + supervisor within this span.
    deadline = System.monotonic_time(:millisecond) + div(3 * @max_seconds * 1000, 2)

    poll_until_deadline(deadline, sup, sibling)

    # Survivors.
    assert Process.alive?(sup), "the supervisor was terminated — intensity tripped"
    assert Process.alive?(sibling), "the sibling PtyServer was wiped by the looper's crash loop"

    # The looper really was crash-looping (multiple restarts recorded)...
    attempts = RespawnBackoff.attempt_count(URI.to_string(looper_uri))
    assert attempts >= 3, "expected the looper to have restarted repeatedly, got #{attempts}"

    # ...but the backoff kept it well under the intensity ceiling.
    assert attempts < @max_restarts,
           "backoff failed to rate-limit the looper (#{attempts} restarts ≥ #{@max_restarts})"
  end

  test "the live PtyServer DynamicSupervisor runs a bounded, non-default intensity" do
    sup = Process.whereis(EzagentDomainPty.Supervisor)
    assert is_pid(sup)

    state = :sys.get_state(sup)
    # Elixir's DynamicSupervisor state carries the configured restart intensity.
    assert state.max_restarts == EzagentDomainPty.Application.max_restarts()
    assert state.max_seconds == EzagentDomainPty.Application.max_seconds()

    # The whole point of the fix: NOT OTP's default 3-in-5s.
    assert state.max_restarts > 3,
           "PtyServer supervisor intensity regressed toward the OTP default — one " <>
             "crash-looping child could wipe every sibling"
  end

  # ---- helpers -------------------------------------------------------

  defp poll_until_deadline(deadline, sup, sibling) do
    now = System.monotonic_time(:millisecond)

    if now >= deadline do
      :ok
    else
      # Fail fast the moment either canary dies, so the failure is attributable.
      assert Process.alive?(sup), "supervisor died mid-loop (intensity tripped)"
      assert Process.alive?(sibling), "sibling died mid-loop (node-wide wipe)"
      Process.sleep(50)
      poll_until_deadline(deadline, sup, sibling)
    end
  end

  defp fresh_uri(prefix) do
    URI.new!("entity://team-alpha/agent/pty_iso_#{prefix}-#{System.unique_integer([:positive])}")
  end
end
