defmodule Ezagent.Domain.Pty.Server.RespawnBreakerTest do
  @moduledoc """
  2026-07-13 — the respawn BREAKER (`Ezagent.Domain.Pty.RespawnPolicy`).

  Live on canary, `test-zyli-cc-1` respawned `claude` 933 times in two hours: the
  cc respawn argv carried `--continue`, nothing was resumable, so the child exited 1
  within 37 ms of every launch — forever. `RespawnBackoff` slowed that to one spawn
  per ~7 s but was never meant to STOP it, and nothing else could: the respawn
  decision was unconditional.

  Two properties are pinned here, and they must not be confused:

    * a child that can NEVER start is retried a BOUNDED number of times and then
      HALTED (the loop ends), and
    * a child that started healthily and later crashed still respawns exactly as
      before (the breaker must not turn an ordinary crash into a dead agent).

  Plus the self-healing path that closes the actual canary bug: when a preferred
  command cannot start and a degraded `cmd_fallback` exists, the fallback is used
  — so cc's `--continue` can no longer PREVENT a start, only fail over to a fresh
  conversation.

  These run REAL children (`test_mode: false`) through the REAL app supervisor, so
  they exercise the same DynamicSupervisor restart path production does — the
  frozen-child-spec replay is the whole reason the veto has to live in ETS.
  """
  use ExUnit.Case, async: false

  alias Ezagent.Domain.Pty
  alias Ezagent.Domain.Pty.RespawnBackoff
  alias Ezagent.Domain.Pty.RespawnPolicy
  alias Ezagent.Domain.Pty.Server, as: PtyServer

  @max_failures 3
  @max_probes 1
  @healthy_after_ms 400

  setup do
    prev =
      Map.new(
        [
          :respawn_max_failures,
          :respawn_max_probes,
          :respawn_healthy_after_ms,
          :respawn_backoff_base_ms,
          :respawn_backoff_cap_ms
        ],
        &{&1, Application.get_env(:ezagent_domain_pty, &1)}
      )

    Application.put_env(:ezagent_domain_pty, :respawn_max_failures, @max_failures)
    # Pin the probe budget too: a leftover value from another suite would otherwise
    # decide whether a written-off primary gets retried here.
    Application.put_env(:ezagent_domain_pty, :respawn_max_probes, @max_probes)
    Application.put_env(:ezagent_domain_pty, :respawn_healthy_after_ms, @healthy_after_ms)
    # Keep the backoff from dominating the wall-clock; it is tested elsewhere.
    Application.put_env(:ezagent_domain_pty, :respawn_backoff_base_ms, 20)
    Application.put_env(:ezagent_domain_pty, :respawn_backoff_cap_ms, 60)

    on_exit(fn ->
      for {k, v} <- prev do
        case v do
          nil -> Application.delete_env(:ezagent_domain_pty, k)
          val -> Application.put_env(:ezagent_domain_pty, k, val)
        end
      end
    end)

    :ok
  end

  describe "a child that can never start" do
    test "is spawned a BOUNDED number of times, then halted — it does not loop forever" do
      %{uri: uri, log: log} = agent()
      # Halt is signalled through the unified phase channel (:dead with reason
      # {:respawn_halted, _}) — no separate halt topic. The first N :dead messages
      # carry the raw exit reason; the halt is the final one.
      Phoenix.PubSub.subscribe(EzagentCore.PubSub, PtyServer.phase_topic(uri))

      {:ok, _} = start_pty(uri, cmd_override: fails_immediately(log, "spawn"))

      assert_receive_until_halted(uri)
      info = RespawnPolicy.halt_info(uri)
      assert info.failures == @max_failures

      # BEFORE the fix this is the assertion that fails: the child was respawned
      # without bound (933 times in 2 h on canary). Give it a generous window to
      # keep spawning — the count must not move.
      Process.sleep(600)

      assert spawn_count(log) == @max_failures,
             "the child was spawned #{spawn_count(log)} times; the breaker must bound it " <>
               "at #{@max_failures}. An unbounded count is the production crash loop."

      # The server stays ALIVE and halted — that is what makes the halt observable
      # (status answers, the buffer survives) and gives the operator something to
      # restart. A dead process would just be another dead end. (It is NOT the
      # process start_pty returned: the supervisor replaced it on each restart.)
      assert Pty.alive?(uri)
      assert RespawnPolicy.halt_info(uri)

      status = Pty.status(uri)
      assert status.halted? == true
      assert status.running == false
      refute is_nil(status.halt_reason)
    end

    test "an operator restart clears the halt and spawns again" do
      %{uri: uri, log: log} = agent()
      {:ok, _pid} = start_pty(uri, cmd_override: fails_immediately(log, "spawn"))

      wait_until(fn -> RespawnPolicy.halt_info(uri) != nil end)
      assert spawn_count(log) == @max_failures

      # The ONLY way back from a halt (there is no other operator control — the
      # world UI exposes create/delete/config and nothing else).
      assert :ok == Pty.restart(uri)

      # It spawns again (and, still being broken, halts again — bounded, not looping).
      wait_until(fn -> spawn_count(log) > @max_failures end)
      assert Pty.halt_info(uri) == nil or spawn_count(log) <= 2 * @max_failures
    end
  end

  describe "operator restart of a HEALTHY agent (codex review, HIGH)" do
    test "does not manufacture a failure, and does not kill the child it just started" do
      %{uri: uri, log: log} = agent()

      # A perfectly healthy, long-running child.
      cmd = ["/bin/sh", "-c", "echo spawn >> #{log}; sleep 30"]
      {:ok, _} = start_pty(uri, cmd_override: cmd)
      wait_until(fn -> spawn_count(log) == 1 end)

      # The defect: `:respawn` stops child A and spawns B inside the same
      # handle_continue, so A's erlexec `:DOWN` is ALREADY queued when B exists. An
      # uncorrelated DOWN clause booked A's exit against B — inventing a failure for a
      # healthy child and then killing it via terminate/2. Operator recovery would
      # corrupt the very accounting this whole PR exists to make trustworthy.
      assert :ok == Pty.restart(uri)

      wait_until(fn -> spawn_count(log) == 2 end)
      # Give A's stale DOWN every chance to land and do damage.
      Process.sleep(400)

      assert spawn_count(log) == 2,
             "the restart spawned #{spawn_count(log)} children; a stale DOWN killed the " <>
               "replacement and the supervisor started yet another"

      assert RespawnPolicy.failures(uri) == 0,
             "a stale DOWN from the replaced child was booked as a failure of its successor"

      assert RespawnPolicy.halt_info(uri) == nil
      assert Pty.alive?(uri)
      assert Pty.status(uri).running == true
    end
  end

  describe "halt diagnosis: :needs_login" do
    test "an auth observer that fired names the halt :needs_login, not an opaque exit code" do
      %{uri: uri, log: log} = agent()

      # A child that prints a credential failure and then dies — the shape of a cc
      # agent whose login expired. Without the tag the operator's only clue is
      # `halt_reason: {:exit_status, 256}`, which says nothing about what to fix.
      cmd = ["/bin/sh", "-c", "echo spawn >> #{log}; echo 'API Error: 403'; exit 1"]

      {:ok, _} =
        start_pty(uri,
          cmd_override: cmd,
          auth_observers: [%{name: :test_403, match: "API Error: 403"}]
        )

      wait_until(fn -> RespawnPolicy.halt_info(uri) != nil end)

      assert %{reason: :needs_login} = RespawnPolicy.halt_info(uri),
             "the auth observer fired for this child, so the halt must be diagnosable as " <>
               ":needs_login rather than an opaque exit status"

      assert Pty.status(uri).halt_reason == :needs_login
    end

    test "a child that dies WITHOUT an auth signal keeps its raw exit reason" do
      %{uri: uri, log: log} = agent()

      # No observer match → no tag. Mis-labelling an ordinary crash as :needs_login
      # would send the operator hunting for a credential problem that is not there.
      {:ok, _} =
        start_pty(uri,
          cmd_override: fails_immediately(log, "spawn"),
          auth_observers: [%{name: :test_403, match: "API Error: 403"}]
        )

      wait_until(fn -> RespawnPolicy.halt_info(uri) != nil end)

      assert {:exit_status, _} = RespawnPolicy.halt_info(uri).reason
    end
  end

  describe "a halt must never become a dead end" do
    test "a deliberate stop/1 clears the halt, so the next start/2 is not vetoed by it" do
      %{uri: uri, log: log} = agent()
      {:ok, _} = start_pty(uri, cmd_override: fails_immediately(log, "spawn"))
      wait_until(fn -> RespawnPolicy.halt_info(uri) != nil end)

      # A halt is durable in ETS and outlives the process. If `stop/1` left it there,
      # a stopped+halted agent would be UNRECOVERABLE: `restart/1` has no server to
      # restart, and any fresh `start/2` would be vetoed by the stale halt forever.
      # `stop/1` is a DELIBERATE teardown and terminate_child already ends the
      # supervisor loop the breaker exists to stop, so it clears the history.
      :ok = Pty.stop(uri)
      assert Pty.halt_info(uri) == nil

      # ...and a fresh start really does spawn again (not silently vetoed).
      before = spawn_count(log)
      {:ok, _} = start_pty(uri, cmd_override: fails_immediately(log, "spawn"))
      wait_until(fn -> spawn_count(log) > before end)
    end
  end

  describe "a child that starts healthily" do
    test "still respawns on a later crash — the breaker does not fire (no false positive)" do
      %{uri: uri, log: log} = agent()

      # Lives past `healthy_after_ms`, THEN dies: an ordinary crash, not a failed
      # start. This must behave exactly as it did before the breaker existed.
      cmd = ["/bin/sh", "-c", "echo spawn >> #{log}; sleep 0.7; exit 1"]
      {:ok, _} = start_pty(uri, cmd_override: cmd)

      # Respawns well past the breaker's ceiling, because a healthy run erases the
      # crash history each time round.
      wait_until(fn -> spawn_count(log) > @max_failures end, 12_000)

      assert RespawnPolicy.halt_info(uri) == nil,
             "an ordinary crash-and-respawn was mistaken for an unrecoverable start"

      assert Pty.alive?(uri)
    end
  end

  describe "cmd_fallback (the --continue fix)" do
    test "a preferred command that cannot start fails over to the degraded one" do
      %{uri: uri, log: log} = agent()

      # Mirrors cc exactly: the preferred argv carries `--continue` and dies at once
      # ("No conversation found to continue"); the fallback is the same argv without
      # it and comes up fine.
      preferred = fails_immediately(log, "preferred")
      fallback = ["/bin/sh", "-c", "echo fallback >> #{log}; sleep 30"]

      {:ok, _} = start_pty(uri, cmd_override: preferred, cmd_fallback: fallback)

      wait_until(fn -> count(log, "fallback") >= 1 end)

      # It tried the preferred command ONCE, then healed itself onto the fallback —
      # instead of respawning the doomed command until the breaker tripped.
      assert count(log, "preferred") == 1
      assert count(log, "fallback") == 1
      assert Pty.alive?(uri)

      # A healthy fallback child clears the history, so a LATER restart is free to
      # try the preferred command again (by then a conversation exists to resume).
      wait_until(fn -> RespawnPolicy.failures(uri) == 0 end)
      assert RespawnPolicy.halt_info(uri) == nil
    end
  end

  # ---- helpers -------------------------------------------------------

  defp agent do
    n = System.unique_integer([:positive])
    uri = URI.new!("entity://team-alpha/agent/pty_breaker-#{n}")
    log = Path.join(System.tmp_dir!(), "pty_breaker_#{n}.log")
    File.rm(log)

    RespawnPolicy.clear(uri)
    RespawnBackoff.clear(URI.to_string(uri))

    on_exit(fn ->
      Pty.stop(uri)
      RespawnPolicy.clear(uri)
      File.rm(log)
    end)

    %{uri: uri, log: log}
  end

  # Records the spawn, then dies at once — a child that can never come up.
  defp fails_immediately(log, tag), do: ["/bin/sh", "-c", "echo #{tag} >> #{log}; exit 1"]

  defp start_pty(uri, opts) do
    Pty.start(uri, Map.merge(%{cwd: "/tmp", test_mode: false}, Map.new(opts)))
  end

  defp spawn_count(log), do: count(log, "spawn")

  defp count(log, tag) do
    case File.read(log) do
      {:ok, body} -> body |> String.split("\n", trim: true) |> Enum.count(&(&1 == tag))
      _ -> 0
    end
  end

  defp wait_until(fun, timeout \\ 6_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_wait(fun, deadline)
  end

  defp do_wait(fun, deadline) do
    cond do
      fun.() -> :ok
      System.monotonic_time(:millisecond) >= deadline -> flunk("condition never became true")
      true -> Process.sleep(50) && do_wait(fun, deadline)
    end
  end

  # Keep consuming {:pty_phase, uri, :dead, _} until we find one whose reason is
  # {:respawn_halted, _} — the halt signal, unified under the phase channel.
  defp assert_receive_until_halted(uri) do
    assert_receive {:pty_phase, ^uri, :dead, meta}, 5_000

    case meta.reason do
      {:respawn_halted, _} -> :ok
      _ -> assert_receive_until_halted(uri)
    end
  end
end
