defmodule Ezagent.Domain.Pty.RespawnPolicyTest do
  @moduledoc """
  The respawn breaker's decision ladder, driven directly (no processes) so the
  CONVERGENCE properties are pinned deterministically.

  The whole point of this module is that no failing agent may respawn without
  bound. A ladder that merely *usually* stops is the bug it was written to kill —
  so each test below is a bound, not a happy path.
  """
  use ExUnit.Case, async: false

  alias Ezagent.Domain.Pty.RespawnPolicy

  @max 3

  setup do
    prev = Application.get_env(:ezagent_domain_pty, :respawn_max_failures)
    Application.put_env(:ezagent_domain_pty, :respawn_max_failures, @max)

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(:ezagent_domain_pty, :respawn_max_failures)
        v -> Application.put_env(:ezagent_domain_pty, :respawn_max_failures, v)
      end
    end)

    uri = URI.new!("entity://team-alpha/agent/policy-#{System.unique_integer([:positive])}")
    RespawnPolicy.clear(uri)
    on_exit(fn -> RespawnPolicy.clear(uri) end)
    %{uri: uri}
  end

  describe "no fallback available" do
    test "retries the primary, then HALTS at max_failures", %{uri: uri} do
      for _ <- 1..(@max - 1) do
        assert RespawnPolicy.decide(uri, false) == :primary
        assert :ok == RespawnPolicy.record_failure(uri, :boom, :primary)
      end

      assert RespawnPolicy.decide(uri, false) == :primary
      assert {:halted, info} = RespawnPolicy.record_failure(uri, :boom, :primary)
      assert info.failures == @max

      # Terminal, and it stays terminal.
      assert {:halt, ^info} = RespawnPolicy.decide(uri, false)
      assert {:halt, ^info} = RespawnPolicy.decide(uri, false)
    end
  end

  describe "fallback available" do
    test "one primary failure switches to the fallback", %{uri: uri} do
      assert RespawnPolicy.decide(uri, true) == :primary
      RespawnPolicy.record_failure(uri, :boom, :primary)
      assert RespawnPolicy.decide(uri, true) == :fallback
    end

    test "a fallback that also cannot start still HALTS — the fallback is not a loophole",
         %{uri: uri} do
      RespawnPolicy.record_failure(uri, :boom, :primary)
      assert RespawnPolicy.decide(uri, true) == :fallback
      RespawnPolicy.record_failure(uri, :boom, :fallback)
      assert RespawnPolicy.decide(uri, true) == :fallback
      assert {:halted, _} = RespawnPolicy.record_failure(uri, :boom, :fallback)
      assert {:halt, _} = RespawnPolicy.decide(uri, true)
    end
  end

  describe "convergence: a healthy fallback must not forgive a broken primary (codex review)" do
    test "the primary/fallback pair cannot cycle forever — the primary gets written off",
         %{uri: uri} do
      # The defect this pins: `record_healthy` used to erase the WHOLE history, so a
      # fallback that survived the health timer wiped the single primary failure that
      # preceded it. The next incarnation then retried the primary, which failed, and
      # the pair cycled indefinitely — never reaching max_failures. Slower than the
      # 37 ms production loop, but just as unbounded.
      for cycle <- 1..@max do
        assert RespawnPolicy.decide(uri, true) == :primary,
               "cycle #{cycle}: expected the primary to still be worth a try"

        RespawnPolicy.record_failure(uri, :no_conversation_to_continue, :primary)

        assert RespawnPolicy.decide(uri, true) == :fallback
        # The fallback comes up and survives the health timer — but never actually
        # works (parked at a dialog), so it exits later without persisting anything.
        RespawnPolicy.record_healthy(uri, :fallback)

        # Consecutive-failure count IS forgiven (it is not crash-looping)...
        assert RespawnPolicy.failures(uri) == 0
        # ...but the knowledge that the primary is broken is NOT.
        assert RespawnPolicy.degraded?(uri)
      end

      # After max_failures primary failures the primary is written off: the ladder
      # settles on the fallback instead of paying another wasted spawn every cycle.
      assert RespawnPolicy.decide(uri, true) == :fallback
      assert RespawnPolicy.decide(uri, true) == :fallback

      # And it never halted — the agent still WORKS, it just stopped retrying a
      # command we now know cannot start.
      assert RespawnPolicy.halt_info(uri) == nil
    end

    test "a healthy PRIMARY forgives everything — resume works again", %{uri: uri} do
      RespawnPolicy.record_failure(uri, :boom, :primary)
      assert RespawnPolicy.degraded?(uri)

      RespawnPolicy.record_healthy(uri, :primary)

      refute RespawnPolicy.degraded?(uri)
      assert RespawnPolicy.failures(uri) == 0
      assert RespawnPolicy.decide(uri, true) == :primary
    end

    test "degraded? survives a healthy fallback run (status must not lie)", %{uri: uri} do
      RespawnPolicy.record_failure(uri, :boom, :primary)
      RespawnPolicy.record_healthy(uri, :fallback)

      # `status/1` reads this. Reporting `degraded?: false` here would hide that
      # `--continue` failed and the agent is running a FRESH conversation.
      assert RespawnPolicy.degraded?(uri)
    end
  end

  describe "operator clear" do
    test "wipes the halt, the failures and the written-off primary", %{uri: uri} do
      for _ <- 1..@max, do: RespawnPolicy.record_failure(uri, :boom, :primary)
      assert {:halt, _} = RespawnPolicy.decide(uri, true)

      RespawnPolicy.clear(uri)

      assert RespawnPolicy.halt_info(uri) == nil
      assert RespawnPolicy.failures(uri) == 0
      refute RespawnPolicy.degraded?(uri)
      assert RespawnPolicy.decide(uri, true) == :primary
    end
  end
end
