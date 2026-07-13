defmodule Ezagent.Domain.Pty.RespawnPolicyTest do
  @moduledoc """
  The respawn breaker's decision ladder, driven directly (no processes) so the
  CONVERGENCE properties are pinned deterministically.

  The whole point of this module is that no failing agent may respawn without
  bound. A ladder that merely *usually* stops is the bug it was written to kill —
  so each test below is a bound, not a happy path.

  Equally, the breaker must not be a ONE-WAY DOOR: a written-off primary that
  later becomes viable again has to be able to come back on its own. That is the
  probe, and it is bounded too.
  """
  use ExUnit.Case, async: false

  alias Ezagent.Domain.Pty.RespawnPolicy

  @max 3
  @probes 1

  setup do
    prev =
      Map.new(
        [:respawn_max_failures, :respawn_max_probes],
        &{&1, Application.get_env(:ezagent_domain_pty, &1)}
      )

    Application.put_env(:ezagent_domain_pty, :respawn_max_failures, @max)
    Application.put_env(:ezagent_domain_pty, :respawn_max_probes, @probes)

    on_exit(fn ->
      for {k, v} <- prev do
        case v do
          nil -> Application.delete_env(:ezagent_domain_pty, k)
          val -> Application.put_env(:ezagent_domain_pty, k, val)
        end
      end
    end)

    uri = URI.new!("entity://team-alpha/agent/policy-#{System.unique_integer([:positive])}")
    RespawnPolicy.clear(uri)
    on_exit(fn -> RespawnPolicy.clear(uri) end)
    %{uri: uri}
  end

  # Failing `mode`'s command once, with/without a fallback in hand.
  defp fail(uri, mode, fallback? \\ true),
    do: RespawnPolicy.record_failure(uri, :boom, mode, fallback?)

  describe "no fallback available" do
    test "retries the primary, then HALTS at max_failures", %{uri: uri} do
      for _ <- 1..(@max - 1) do
        assert RespawnPolicy.decide(uri, false) == :primary
        assert :ok == fail(uri, :primary, false)
      end

      assert RespawnPolicy.decide(uri, false) == :primary
      assert {:halted, info} = fail(uri, :primary, false)
      assert info.failures == @max

      # Terminal, and it stays terminal.
      assert {:halt, ^info} = RespawnPolicy.decide(uri, false)
      assert {:halt, ^info} = RespawnPolicy.decide(uri, false)
    end
  end

  describe "fallback available" do
    test "one primary failure switches to the fallback", %{uri: uri} do
      assert RespawnPolicy.decide(uri, true) == :primary
      fail(uri, :primary)
      assert RespawnPolicy.decide(uri, true) == :fallback
    end

    test "a fallback that also cannot start still HALTS — the fallback is not a loophole",
         %{uri: uri} do
      fail(uri, :primary)
      assert RespawnPolicy.decide(uri, true) == :fallback
      fail(uri, :fallback)
      assert RespawnPolicy.decide(uri, true) == :fallback
      assert {:halted, _} = fail(uri, :fallback)
      assert {:halt, _} = RespawnPolicy.decide(uri, true)
    end

    test "max_failures: 1 still reaches the fallback — the halt must not pre-empt it",
         %{uri: uri} do
      # codex review P4. `record_failure` used to halt the moment consecutive
      # failures hit the threshold, which for the perfectly valid `max_failures: 1`
      # meant the FIRST primary failure went straight to a terminal halt and the
      # fallback — the whole self-healing path — was never tried at all. The
      # write-off crossing must win over the halt while a fallback is still in hand.
      Application.put_env(:ezagent_domain_pty, :respawn_max_failures, 1)

      assert RespawnPolicy.decide(uri, true) == :primary
      assert :ok == fail(uri, :primary)

      assert RespawnPolicy.decide(uri, true) == :fallback,
             "the primary was written off but the fallback was never reached — the agent " <>
               "halts instead of healing"

      # ...and the breaker still trips when the FALLBACK is the one failing.
      assert {:halted, _} = fail(uri, :fallback)
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
      #
      # First primary failure: the ladder switches to the fallback.
      assert RespawnPolicy.decide(uri, true) == :primary
      fail(uri, :primary)
      assert RespawnPolicy.decide(uri, true) == :fallback

      # The PATHOLOGICAL fallback: it survives the health timer but never actually
      # works (parked at a dialog), so it exits later without persisting anything.
      # In the old code its healthy run erased the whole history — including the
      # primary's failure — so the next round retried the primary from scratch and
      # the pair cycled FOREVER, never reaching max_failures.
      #
      # Now each round costs the primary one strike that is never refunded. Run
      # enough rounds to burn through them and show the ladder settles.
      for _ <- 1..(@max + 2) do
        RespawnPolicy.record_healthy(uri, :fallback)

        # The consecutive-failure count IS forgiven (it is not crash-looping)...
        assert RespawnPolicy.failures(uri) == 0
        # ...but the knowledge that the primary is broken is NOT.
        assert RespawnPolicy.degraded?(uri)

        # Whatever the ladder answers, feed the outcome back: a probe (if one was
        # banked) retries the primary and fails; otherwise we are already settled.
        case RespawnPolicy.decide(uri, true) do
          :primary -> fail(uri, :primary)
          :fallback -> :settled
        end
      end

      # Settled on the fallback: the primary is written off, every probe spent. The
      # agent keeps WORKING — it just stopped paying a wasted spawn per restart to
      # retry a command we now know cannot start. THIS is the bound the old code
      # did not have.
      assert RespawnPolicy.decide(uri, true) == :fallback
      assert RespawnPolicy.decide(uri, true) == :fallback

      # And it never halted — a broken PRIMARY is a degradation, not a dead agent.
      assert RespawnPolicy.halt_info(uri) == nil
    end

    test "a healthy PRIMARY forgives everything — resume works again", %{uri: uri} do
      fail(uri, :primary)
      assert RespawnPolicy.degraded?(uri)

      RespawnPolicy.record_healthy(uri, :primary)

      refute RespawnPolicy.degraded?(uri)
      assert RespawnPolicy.failures(uri) == 0
      assert RespawnPolicy.decide(uri, true) == :primary
    end

    test "degraded? survives a healthy fallback run (status must not lie)", %{uri: uri} do
      fail(uri, :primary)
      RespawnPolicy.record_healthy(uri, :fallback)

      # `status/1` reads this. Reporting `degraded?: false` here would hide that
      # `--continue` failed and the agent is running a FRESH conversation.
      assert RespawnPolicy.degraded?(uri)
    end
  end

  describe "the probe: a write-off is not a one-way door" do
    test "a healthy fallback banks a probe, which re-tries the written-off primary",
         %{uri: uri} do
      # Without this, the write-off is PERMANENT: `decide/2` returns :fallback
      # forever, so the primary is never run, so `record_healthy(:primary)` can never
      # fire, so nothing ever forgives it. For cc that means the agent silently loses
      # conversation resume FOREVER — the very regression `--continue` exists to
      # prevent, made permanent by the thing meant to protect us.
      for _ <- 1..@max, do: fail(uri, :primary)

      assert RespawnPolicy.decide(uri, true) == :fallback
      assert RespawnPolicy.probes(uri) == 0

      # The fallback comes up and RUNS — the child really worked, so whatever broke
      # the primary may well be fixed now (for cc: a conversation now exists, so the
      # `--continue` that was written off would resolve).
      RespawnPolicy.record_healthy(uri, :fallback)
      assert RespawnPolicy.probes(uri) == 1

      assert RespawnPolicy.decide(uri, true) == :primary,
             "the banked probe must re-try the primary — otherwise the write-off is a " <>
               "one-way door and resume is lost forever"
    end

    test "a SUCCESSFUL probe fully rehabilitates the primary", %{uri: uri} do
      for _ <- 1..@max, do: fail(uri, :primary)
      RespawnPolicy.record_healthy(uri, :fallback)
      assert RespawnPolicy.decide(uri, true) == :primary

      # The probe's primary comes up healthy — the preferred command works again.
      RespawnPolicy.record_healthy(uri, :primary)

      refute RespawnPolicy.degraded?(uri)
      assert RespawnPolicy.probes(uri) == 0
      assert RespawnPolicy.decide(uri, true) == :primary
    end

    test "a FAILED probe is spent — it cannot retry the doomed primary every restart",
         %{uri: uri} do
      for _ <- 1..@max, do: fail(uri, :primary)
      RespawnPolicy.record_healthy(uri, :fallback)
      assert RespawnPolicy.decide(uri, true) == :primary

      # The probe fails. If the probe were not CONSUMED here, decide/2 would keep
      # answering :primary on every restart — the unbounded primary/fallback cycle
      # in another costume.
      fail(uri, :primary)

      assert RespawnPolicy.probes(uri) == 0
      assert RespawnPolicy.decide(uri, true) == :fallback
      assert RespawnPolicy.decide(uri, true) == :fallback
    end

    test "probes are CAPPED — a long-running fallback cannot bank an unbounded retry budget",
         %{uri: uri} do
      for _ <- 1..@max, do: fail(uri, :primary)

      # Many healthy fallback runs...
      for _ <- 1..10, do: RespawnPolicy.record_healthy(uri, :fallback)

      # ...still buy at most `max_probes` retries of the primary. This is what keeps
      # the probe from re-creating the cycle: the budget cannot grow without bound.
      assert RespawnPolicy.probes(uri) == @probes
    end

    test "a failing probe still leaves the agent WORKING on the fallback (no halt)",
         %{uri: uri} do
      for _ <- 1..@max, do: fail(uri, :primary)

      # Several probe cycles, all failing. The agent must keep running the fallback —
      # a broken PRIMARY is a degradation, not a reason to take the agent down.
      for _ <- 1..5 do
        RespawnPolicy.record_healthy(uri, :fallback)
        assert RespawnPolicy.decide(uri, true) == :primary
        fail(uri, :primary)
        assert RespawnPolicy.decide(uri, true) == :fallback
      end

      assert RespawnPolicy.halt_info(uri) == nil
      assert RespawnPolicy.degraded?(uri)
    end
  end

  describe "operator clear" do
    test "wipes the halt, the failures, the probes and the written-off primary", %{uri: uri} do
      for _ <- 1..@max, do: fail(uri, :primary, false)
      assert {:halt, _} = RespawnPolicy.decide(uri, false)

      RespawnPolicy.clear(uri)

      assert RespawnPolicy.halt_info(uri) == nil
      assert RespawnPolicy.failures(uri) == 0
      assert RespawnPolicy.probes(uri) == 0
      refute RespawnPolicy.degraded?(uri)
      assert RespawnPolicy.decide(uri, true) == :primary
    end
  end
end
