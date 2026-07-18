defmodule Ezagent.Domain.Pty.E2E.Category07PtyTest do
  @moduledoc """
  E2E scenarios — Category 7: PTY interaction.

  Maps to `docs/scenarios/18-pty-first-run/scenario.md` and
  `docs/scenarios/19-pty-restart-orphan/scenario.md`.

  ## Mock strategy

  Real `claude` first-run / restart cycles need:

  - The `claude` CLI installed + authenticated
  - A real PTY allocated via `erlexec`
  - 5-30s of wall-clock time per spawn
  - Anthropic API quota

  None of those are present in the test sandbox. The production code
  already supports `test_mode: true` (short-circuits `:exec.run/2`)
  which is the mock pattern we use here.

  Crucially, `test_mode: true` is NOT a stub — it still:

  - Allocates the GenServer + registers it under
    `EzagentDomainPty.Registry` keyed by the agent URI.
  - Walks the canonical phase state machine (`:starting → :running`).
  - Broadcasts `:starting` and `:running` over PubSub at
    `pty:phase:<agent_uri>`.
  - Responds to `Pty.lookup/1`, `Pty.alive?/1`, `Pty.status/1`,
    `Pty.stop/1`.
  - Accepts `write_input/2` calls and returns `:ok` (no bytes
    physically reach a PTY — the mock IS the seam).

  This matches the production observable contract from the perspective
  of every caller other than the OS subprocess itself, so any
  regression in the Domain.Pty facade or phase state-machine surfaces
  here.

  The Behavior-level dispatch path (`entity://agent/.../?action=pty.write`)
  is exercised end-to-end via `Ezagent.Invocation.dispatch/1`, with the
  slice-counter assertion verifying the dispatch reached the right
  PtyServer.

  ## Allen-manual gaps

  Scenarios requiring REAL spawn behaviour (claude first-run dialog
  auto-dismiss, real orphan reap via SIGTERM, real cwd-preservation
  on restart with a live claude process) appear as
  `@moduletag :requires_allen` skeletons.

  See `docs/scenarios/18-pty-first-run/scenario.md` and
  `19-pty-restart-orphan/scenario.md`.
  """

  use ExUnit.Case, async: false

  alias Ezagent.Domain.Pty
  alias Ezagent.Domain.Pty.Server, as: PtyServer
  alias Ezagent.Invocation

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(EzagentCore.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    :ok
  end

  # ============================================================
  # Scenario 18 — first-run phase (lifecycle observability)
  # ============================================================

  describe "scenario 18 — PTY first-run phase observability (test_mode)" do
    @describetag scenario: "18-pty-first-run"

    test "Pty.start/2 brings up a server reachable via the facade" do
      uri = fresh_uri()
      {:ok, pid} = Pty.start(uri, %{cwd: "/tmp", test_mode: true})

      on_exit(fn -> if Process.alive?(pid), do: :ok = Pty.stop(uri) end)

      # Facade observables — all the surfaces Domain.Pty exposes.
      assert {:ok, ^pid} = Pty.lookup(uri)
      assert Pty.alive?(uri) == true
      # status snapshot reflects the live process.
      status = Pty.status(uri)
      assert status.agent_uri == uri
      assert status.running == true
    end

    test ":starting → :running phase sequence broadcasts on PubSub" do
      uri = fresh_uri()
      :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, PtyServer.phase_topic(uri))

      {:ok, pid} = Pty.start(uri, %{cwd: "/tmp", test_mode: true})
      on_exit(fn -> if Process.alive?(pid), do: :ok = Pty.stop(uri) end)

      # The first broadcast lands inside init/1 BEFORE handle_continue
      # runs — proves the operator sees "process is spinning up"
      # before any spawn attempt.
      assert_receive {:pty_phase, ^uri, :starting, _meta}, 1_000

      # Second broadcast — handle_continue(test_mode) flipped to :running.
      assert_receive {:pty_phase, ^uri, :running, %{os_pid: nil}}, 1_000

      # And the public phase accessor agrees.
      Process.sleep(20)
      assert PtyServer.phase(uri) == :running
    end

    test "Pty.alive?/1 + Pty.phase/1 cleanly say :dead for a never-existed agent" do
      ghost = fresh_uri("never_spawned")
      assert Pty.alive?(ghost) == false
      assert PtyServer.phase(ghost) == :dead
      assert Pty.status(ghost) == nil
    end
  end

  # ============================================================
  # Scenario 18 — write input via dispatch (the Behavior.Pty seam)
  # ============================================================

  describe "scenario 18 — operator typing reaches PtyServer via dispatch" do
    @describetag scenario: "18-pty-first-run"

    test "100-byte stream via dispatch hits the test_mode PtyServer + bumps slice counters" do
      # This is the IMPLEMENTATION_ROADMAP §1.3 invariant: every
      # operator-typed byte goes through dispatch (no direct PtyServer
      # writes from LV).
      agent_uri = fresh_uri("dispatch_bytes")
      {:ok, _kind} = EzagentDomainPty.Test.PtyAgentFixture.spawn(agent_uri)
      {:ok, pty} = Pty.start(agent_uri, %{cwd: "/tmp", test_mode: true})
      on_exit(fn -> if Process.alive?(pty), do: :ok = Pty.stop(agent_uri) end)

      target = URI.parse(URI.to_string(agent_uri) <> "?action=pty.write")

      for i <- 1..100 do
        assert {:ok, %{bytes_written: 1}} =
                 dispatch(%Invocation{
                   origin: :trusted_internal,
                   target: target,
                   mode: :call,
                   args: %{bytes: <<i>>},
                   ctx: admin_ctx()
                 })
      end

      # The slice on the agent Kind reflects every dispatched write —
      # this is the "mock produces accurate state" half of the
      # mock-not-stub rule.
      {:ok, kind_pid} = Ezagent.KindRegistry.lookup(agent_uri)
      state = :sys.get_state(kind_pid, 500)
      slice = pty_slice_state(state.state.pty)

      assert slice.write_calls >= 100
      assert slice.total_bytes >= 100
    end

    test "dispatch against an agent with no PtyServer → :no_pty_server" do
      # Spawn the Agent Kind so dispatch resolves the Behavior, but
      # DON'T start a PtyServer. The Behavior.handle_write must surface
      # `:no_pty_server` rather than silently succeed.
      bare = fresh_uri("no_pty")
      {:ok, _kind} = EzagentDomainPty.Test.PtyAgentFixture.spawn(bare)

      target = URI.parse(URI.to_string(bare) <> "?action=pty.write")

      assert {:error, :no_pty_server} =
               dispatch(%Invocation{
                 origin: :trusted_internal,
                 target: target,
                 mode: :call,
                 args: %{bytes: "x"},
                 ctx: admin_ctx()
               })
    end
  end

  # ============================================================
  # Scenario 19 — restart (stop → re-start preserves cwd)
  # ============================================================

  describe "scenario 19 — restart preserves cwd + lookup recovers" do
    @describetag scenario: "19-pty-restart-orphan"

    test "after stop/1 + restart, Pty.lookup/1 + status reflect the NEW server with same cwd" do
      uri = fresh_uri("restart")
      cwd = "/tmp"

      {:ok, pid1} = Pty.start(uri, %{cwd: cwd, test_mode: true})
      assert {:ok, ^pid1} = Pty.lookup(uri)
      pre_status = Pty.status(uri)
      assert pre_status.cwd == cwd

      # Operator restart — stop the server.
      :ok = Pty.stop(uri)

      # Polling for shutdown completion — under :via Registry the name
      # unregisters when the process dies.
      assert eventually(fn -> Pty.alive?(uri) == false end, 500)

      # Restart with the SAME cwd — production restart preserves the
      # agent's cwd setting, mirroring `Behavior.Agent :restart` flow.
      {:ok, pid2} = Pty.start(uri, %{cwd: cwd, test_mode: true})
      on_exit(fn -> if Process.alive?(pid2), do: :ok = Pty.stop(uri) end)

      refute pid1 == pid2
      assert {:ok, ^pid2} = Pty.lookup(uri)

      post_status = Pty.status(uri)
      assert post_status.cwd == cwd
      assert post_status.agent_uri == uri
      assert post_status.running == true
    end

    test "terminate/2 emits the terminal :dead phase exactly once" do
      uri = fresh_uri("dead_phase")
      :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, PtyServer.phase_topic(uri))

      {:ok, pid} = Pty.start(uri, %{cwd: "/tmp", test_mode: true})

      # Drain the startup phases so the test only observes the :dead
      # broadcast triggered by the stop call below.
      assert_receive {:pty_phase, ^uri, :starting, _}, 1_000
      assert_receive {:pty_phase, ^uri, :running, _}, 1_000

      :ok = Pty.stop(uri)

      assert_receive {:pty_phase, ^uri, :dead, %{reason: _}}, 1_000

      # `dead_broadcast?: true` guards idempotency — no second emit.
      refute_receive {:pty_phase, ^uri, :dead, _}, 200
      refute Process.alive?(pid)
    end

    test "concurrent Pty.start/2 for the same agent_uri collapses to a single registered process" do
      # PR-D2 invariant: start_link via :via Registry returns
      # `{:error, {:already_started, pid}}` for the second concurrent
      # caller — no two PtyServers can coexist for one agent.
      uri = fresh_uri("collision")

      {:ok, pid1} = Pty.start(uri, %{cwd: "/tmp", test_mode: true})
      on_exit(fn -> if Process.alive?(pid1), do: :ok = Pty.stop(uri) end)

      # Second start — under DynamicSupervisor + :via Registry this
      # surfaces as either an already_started tuple or an error inside
      # the supervisor's start child result.
      result = Pty.start(uri, %{cwd: "/tmp", test_mode: true})

      assert match?({:error, {:already_started, ^pid1}}, result) or
               match?({:ok, ^pid1}, result),
             "expected the second concurrent start for the same agent URI " <>
               "to collapse onto pid1; got: #{inspect(result)}"
    end
  end

  # ============================================================
  # Scenario 19 — orphan reap (no real claude process)
  # ============================================================

  describe "scenario 19 — orphan reap (file-system seam)" do
    @describetag scenario: "19-pty-restart-orphan"

    test "PidFile.write succeeds in test_mode and writes a parseable pid file" do
      # The orphan reaper (cc plugin) discovers prior-incarnation
      # children by walking pid files written here at spawn time.
      # Test_mode doesn't spawn a real OS process, so we exercise
      # PidFile directly to verify the format the reaper consumes.
      tmp_home =
        Path.join(System.tmp_dir!(), "ezagent-pty-e2e-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_home)
      prev_home = System.get_env("EZAGENT_HOME")
      prev_profile = System.get_env("EZAGENT_PROFILE")
      System.put_env("EZAGENT_HOME", tmp_home)
      System.put_env("EZAGENT_PROFILE", "pty-e2e")

      on_exit(fn ->
        if prev_home,
          do: System.put_env("EZAGENT_HOME", prev_home),
          else: System.delete_env("EZAGENT_HOME")

        if prev_profile,
          do: System.put_env("EZAGENT_PROFILE", prev_profile),
          else: System.delete_env("EZAGENT_PROFILE")

        File.rm_rf!(tmp_home)
      end)

      uri = fresh_uri("pidfile")
      # Use our own OS pid — guaranteed parseable + alive.
      own_pid = String.to_integer(System.pid())
      assert :ok = Ezagent.Runtime.PidFile.write("cc", uri, own_pid)

      path = Ezagent.Runtime.PidFile.file_path("cc", uri)
      assert File.exists?(path)
      contents = File.read!(path)
      # File has at least the OS pid as the first line.
      [first_line | _] = String.split(contents, "\n")
      assert String.to_integer(first_line) == own_pid
    end
  end

  # ============================================================
  # Allen-manual scenarios — skeletons
  # ============================================================

  describe "scenario 18/19 — REAL claude PTY behavior (Allen-manual only)" do
    @describetag :requires_allen
    @describetag :requires_claude
    @describetag scenario: "18-pty-first-run"

    @tag :skip
    test "real claude first-run theme dialog auto-dismiss via :dev_channels_dialog prompt" do
      # Requires:
      #   - `claude` CLI installed (binary on $PATH)
      #   - A FRESH claude_config_dir (no themes.json)
      #   - erlexec + a real PTY (no test_mode)
      # Expected behavior:
      #   - PtyServer sees the `Loading development channels` prompt
      #   - default_auto_prompts/0 entry :dev_channels_dialog matches
      #   - "1\r" is sent on the PTY stdin
      #   - claude proceeds past the dialog
      # Verification surface: PR #390 telemetry [:ezagent, :pty,
      # :first_run_dismissed] + agent-browser screenshot of
      # /admin/agents/<uri>/terminal showing the REPL prompt.
      flunk("requires real claude binary + fresh config_dir — Allen-manual scenario only")
    end

    @tag :skip
    test "real restart: SIGTERM kills old claude, new spawn keeps cwd, themes.json persists" do
      # Requires a live claude process. The test_mode equivalent above
      # exercises everything OBSERVABLE through Domain.Pty — the
      # remaining gap is "real SIGTERM happens" + "themes.json round
      # trip" + "second-run skips the dialog".
      flunk("requires real claude + SIGTERM verification — Allen-manual scenario only")
    end

    @tag :skip
    test "orphan reap kills lingering claude process after BEAM crash" do
      # Requires:
      #   - Start a claude via PtyServer (real)
      #   - kill -9 the BEAM (or simulate via Process.exit(:kill))
      #   - Restart BEAM; OrphanReaper.reap/0 should find the pid file
      #     and send SIGTERM to the lingering claude pid
      # The unit-level reaper test exists (apps/ezagent_plugin_cc/test/orphan_reaper_test.exs).
      # The end-to-end SIGTERM-against-real-claude check is what's
      # parked under :requires_allen.
      flunk("requires real claude + multi-BEAM lifecycle — Allen-manual scenario only")
    end
  end

  # ============================================================
  # Helpers
  # ============================================================

  defp fresh_uri(prefix \\ "test") do
    URI.new!("entity://team-alpha/agent/cc_#{prefix}-#{System.unique_integer([:positive])}")
  end

  defp admin_ctx do
    %{
      caller: Ezagent.Entity.User.admin_uri(),
      caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()]),
      reply: {:caller_inbox, self()}
    }
  end

  defp pty_slice_state(%{state: state}) when is_map(state), do: state
  defp pty_slice_state(slice), do: slice

  defp dispatch(%Invocation{} = invocation) do
    invocation
    |> Ezagent.Test.CapHelper.signed_invocation!(:pty_e2e)
    |> Invocation.dispatch()
  end

  defp eventually(fun, timeout_ms) when timeout_ms > 0 do
    case fun.() do
      true ->
        true

      _ ->
        Process.sleep(10)
        eventually(fun, timeout_ms - 10)
    end
  end

  defp eventually(_fun, _), do: false
end
