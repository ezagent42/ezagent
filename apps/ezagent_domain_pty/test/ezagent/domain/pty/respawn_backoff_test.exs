defmodule Ezagent.Domain.Pty.RespawnBackoffTest do
  @moduledoc """
  Unit tests for the crash-loop respawn rate-limiter (cc-PTY hardening
  2026-07-10, audit #3). Deterministic — no real processes; drives the
  sliding-window math + pruning directly.
  """
  use ExUnit.Case, async: false

  alias Ezagent.Domain.Pty.RespawnBackoff

  @base 100
  @cap 500
  @window 1_000

  setup do
    prev = %{
      base: Application.get_env(:ezagent_domain_pty, :respawn_backoff_base_ms),
      cap: Application.get_env(:ezagent_domain_pty, :respawn_backoff_cap_ms),
      window: Application.get_env(:ezagent_domain_pty, :respawn_backoff_window_ms)
    }

    Application.put_env(:ezagent_domain_pty, :respawn_backoff_base_ms, @base)
    Application.put_env(:ezagent_domain_pty, :respawn_backoff_cap_ms, @cap)
    Application.put_env(:ezagent_domain_pty, :respawn_backoff_window_ms, @window)

    on_exit(fn ->
      for {k, app_key} <- [
            {prev.base, :respawn_backoff_base_ms},
            {prev.cap, :respawn_backoff_cap_ms},
            {prev.window, :respawn_backoff_window_ms}
          ] do
        case k do
          nil -> Application.delete_env(:ezagent_domain_pty, app_key)
          v -> Application.put_env(:ezagent_domain_pty, app_key, v)
        end
      end
    end)

    key = "entity://team/agent/backoff-#{System.unique_integer([:positive])}"
    on_exit(fn -> RespawnBackoff.clear(key) end)
    {:ok, key: key}
  end

  test "first attempt has zero delay", %{key: key} do
    assert RespawnBackoff.delay_for(key) == 0
  end

  test "rapid successive attempts escalate linearly then cap", %{key: key} do
    # attempt N sees (N-1) prior recent attempts → delay = base * (N-1), capped.
    assert RespawnBackoff.delay_for(key) == 0
    assert RespawnBackoff.delay_for(key) == @base
    assert RespawnBackoff.delay_for(key) == 2 * @base
    assert RespawnBackoff.delay_for(key) == 3 * @base
    assert RespawnBackoff.delay_for(key) == 4 * @base
    # 5 priors → 5*100 = 500 = cap; further attempts stay capped.
    assert RespawnBackoff.delay_for(key) == @cap
    assert RespawnBackoff.delay_for(key) == @cap
    assert RespawnBackoff.delay_for(key) == @cap
  end

  test "a child that stabilizes past the window returns to zero (no reset timer)", %{key: key} do
    assert RespawnBackoff.delay_for(key) == 0
    assert RespawnBackoff.delay_for(key) == @base
    assert RespawnBackoff.delay_for(key) == 2 * @base

    # Let the whole window elapse so every recorded attempt ages out.
    Process.sleep(@window + 100)

    assert RespawnBackoff.attempt_count(key) == 0
    # Next spawn is treated as a fresh, un-throttled start.
    assert RespawnBackoff.delay_for(key) == 0
  end

  test "attempt_count reflects recent attempts without recording a new one", %{key: key} do
    assert RespawnBackoff.attempt_count(key) == 0
    RespawnBackoff.delay_for(key)
    RespawnBackoff.delay_for(key)
    assert RespawnBackoff.attempt_count(key) == 2
    # attempt_count itself must not record.
    assert RespawnBackoff.attempt_count(key) == 2
  end

  test "clear/1 forgets a key's crash history", %{key: key} do
    RespawnBackoff.delay_for(key)
    RespawnBackoff.delay_for(key)
    assert RespawnBackoff.attempt_count(key) > 0
    :ok = RespawnBackoff.clear(key)
    assert RespawnBackoff.attempt_count(key) == 0
    assert RespawnBackoff.delay_for(key) == 0
  end

  test "distinct agents are throttled independently", %{key: key} do
    other = key <> "-other"
    on_exit(fn -> RespawnBackoff.clear(other) end)

    RespawnBackoff.delay_for(key)
    RespawnBackoff.delay_for(key)
    # `other` has no history → still zero delay.
    assert RespawnBackoff.delay_for(other) == 0
  end
end
