defmodule Ezagent.ActionSet.PtyTest do
  @moduledoc """
  PR #146 (SPEC v2 §5.7) invariant — PTY input goes through
  `Ezagent.Invocation.dispatch` against the agent's own URI (per
  IMPLEMENTATION_ROADMAP §1.3 #1).

  The previous synthetic `pty-input://default` singleton Kind is
  dissolved. Dispatch target is now:
  `entity://agent/<flavor>_<name>?action=pty.write`.

  Domain.Pty PR-B (2026-05-21 SPEC v1): test moved from
  `apps/ezagent_plugin_cc/test/pty_input_dispatch_test.exs` to
  `apps/ezagent_domain_pty/test/ezagent/behavior/pty_test.exs`
  alongside the Behavior module move. Test logic unchanged.

  Sends N writes via dispatch and asserts:
  1. The slice counter (write_calls, total_bytes) reflects every write
     on the live Agent Kind's `:pty` slice (proves the Behavior was
     invoked on the agent, not on a shared singleton)
  2. Each dispatch returns `{:ok, _}` (proves CapBAC passed for admin)
  3. test_mode PtyServer received the writes (proves the Pty Behavior
     resolved the right PtyServer from `ctx.self_uri`)

  If a future change makes Pty-Web push input directly into a PubSub
  topic the PtyServer reads, this test still passes for that input
  path BUT the slice counter wouldn't increment for the bypass path —
  the gate is "everything operator-typed goes through this dispatch
  target and the slice counts reflect it".
  """
  # PR #146: Agent Kind is `persistence :on_terminate` (snapshot path),
  # so the test needs a DB sandbox checkout to spawn it. DataCase
  # provides that via `setup` on every test.
  use EzagentCore.DataCase, async: false

  alias Ezagent.Invocation

  setup do
    # Stable agent name (no random suffix) so spawn_or_resume idempotency
    # is exercised across tests; per-test PtyServer write_calls counter is
    # asserted with `>=` to tolerate cross-test accumulation.
    name = "cc_pty-input-test-#{System.unique_integer([:positive])}"
    agent_uri = Ezagent.URI.new!("entity://team-alpha/agent/#{name}")

    # Ensure a PTY-capable test Kind is alive so dispatch against
    # `entity://agent/<name>?action=pty.write` resolves. This is a
    # Domain.Pty fixture, not real Agent provisioning.
    {:ok, _kind_pid} = EzagentDomainPty.Test.PtyAgentFixture.spawn(agent_uri)

    {:ok, pty_pid} =
      Ezagent.Domain.Pty.start(agent_uri, %{
        cwd: File.cwd!(),
        test_mode: true
      })

    on_exit(fn ->
      if Process.alive?(pty_pid), do: Process.exit(pty_pid, :shutdown)
    end)

    {:ok, agent_uri: agent_uri, pty_pid: pty_pid}
  end

  defp admin_ctx do
    %{
      caller: Ezagent.Entity.User.admin_uri(),
      caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()]),
      reply: {:caller_inbox, self()}
    }
  end

  defp dispatch_target(agent_uri),
    do: URI.parse(URI.to_string(agent_uri) <> "?action=pty.write")

  test "100-byte stream via dispatch hits PtyServer + bumps slice counters", %{
    agent_uri: agent_uri,
    pty_pid: _pid
  } do
    payloads = for i <- 1..100, do: <<i>>
    target = dispatch_target(agent_uri)

    Enum.each(payloads, fn payload ->
      assert {:ok, %{bytes_written: 1}} =
               Invocation.dispatch(%Invocation{
                 target: target,
                 mode: :call,
                 args: %{bytes: payload},
                 ctx: admin_ctx()
               })
    end)

    # Invariant: the Agent Kind's `:pty` slice has cumulative counters
    # from this stream (each test uses a fresh agent URI, so == 100).
    {:ok, kind_pid} = Ezagent.KindRegistry.lookup(agent_uri)
    state = :sys.get_state(kind_pid, 500)
    slice = pty_slice_state(state.state.pty)

    assert slice.write_calls >= 100
    assert slice.total_bytes >= 100
  end

  test "non-admin without per-agent pty cap → :unauthorized", %{agent_uri: agent_uri} do
    non_admin_ctx = %{
      caller: Ezagent.URI.new!("entity://team-alpha/user/non-admin-pty-test"),
      caps: MapSet.new(),
      reply: {:caller_inbox, self()}
    }

    assert {:error, :unauthorized} =
             Invocation.dispatch(%Invocation{
               target: dispatch_target(agent_uri),
               mode: :call,
               args: %{bytes: "x"},
               ctx: non_admin_ctx
             })
  end

  # ---------------------------------------------------------------
  # `pty.restart` is gated by the MANAGE authority (see required_caps/0).
  # These three pin the exact authorization shape — they are the reason
  # the creator needs no new capability and no backfill.
  # ---------------------------------------------------------------

  defp creator_uri, do: Ezagent.URI.new!("entity://team-alpha/user/agent-creator")

  defp write_cap(agent_uri) do
    %Ezagent.Capability{
      kind: :agent,
      behavior: Ezagent.ActionSet.Pty,
      action: :write,
      instance: agent_uri,
      workspace_uri: Ezagent.URI.new!("workspace://team-alpha"),
      granted_by: creator_uri(),
      granted_at: DateTime.utc_now()
    }
  end

  defp restart_target(agent_uri),
    do: URI.parse(URI.to_string(agent_uri) <> "?action=pty.restart")

  # EXACTLY the cap `Ezagent.ActionSet.Workspace.AgentCreate` mints for the
  # creator today, via `CreatorGrant.manage_cap/4`. Nothing added.
  defp creator_ctx(agent_uri) do
    # `workspace://team-alpha` is the PRODUCTION shape: agent creation passes
    # `socket.assigns.current_workspace_uri`, which `agent_actions.ex:70`
    # pattern-matches as `%URI{scheme: "workspace"}`. Written as a literal on
    # purpose — deriving it with `Capability.workspace_of/1` would just mirror
    # the runtime's own derivation and prove nothing.
    cap =
      Ezagent.CreatorGrant.manage_cap(
        :agent,
        agent_uri,
        Ezagent.URI.new!("workspace://team-alpha"),
        creator_uri()
      )

    %{caller: creator_uri(), caps: MapSet.new([cap]), reply: {:caller_inbox, self()}}
  end

  test "creator's EXISTING manage cap authorizes pty.restart — no new grant", %{
    agent_uri: agent_uri
  } do
    # The whole point: the creator holds ONE cap (Manage/:any/this-agent) and
    # it must carry `pty.restart`. Anything but :unauthorized proves authz
    # passed and the handler ran.
    refute match?(
             {:error, :unauthorized},
             Invocation.dispatch(%Invocation{
               target: restart_target(agent_uri),
               mode: :call,
               args: %{},
               ctx: creator_ctx(agent_uri)
             })
           )
  end

  test "a manage cap for ANOTHER agent does NOT authorize pty.restart", %{agent_uri: agent_uri} do
    other = Ezagent.URI.new!("entity://team-alpha/agent/cc_someone-elses-agent")

    assert {:error, :unauthorized} =
             Invocation.dispatch(%Invocation{
               target: restart_target(agent_uri),
               mode: :call,
               args: %{},
               ctx: creator_ctx(other)
             })
  end

  test "a pty:write cap does NOT authorize pty.restart", %{agent_uri: agent_uri} do
    assert {:error, :unauthorized} =
             Invocation.dispatch(%Invocation{
               target: restart_target(agent_uri),
               mode: :call,
               args: %{},
               ctx: %{
                 caller: creator_uri(),
                 caps: MapSet.new([write_cap(agent_uri)]),
                 reply: {:caller_inbox, self()}
               }
             })
  end

  test "a CONCRETE-action pty:write cap authorizes pty.write (the /login hatch)", %{
    agent_uri: agent_uri
  } do
    # The other half of the gap: typing into the terminal. A concrete-action
    # cap (NOT `action: :any`) suffices — which also sidesteps
    # `CapabilityRegistry`'s `:wildcard_action_grant_requires_admin_authority`
    # guard on exact-instance `:any`-action grants.
    assert {:ok, %{bytes_written: 1}} =
             Invocation.dispatch(%Invocation{
               target: dispatch_target(agent_uri),
               mode: :call,
               args: %{bytes: "x"},
               ctx: %{
                 caller: creator_uri(),
                 caps: MapSet.new([write_cap(agent_uri)]),
                 reply: {:caller_inbox, self()}
               }
             })
  end

  test "Behavior.Pty registered on Entity.Agent for :write" do
    assert {:ok, Ezagent.ActionSet.Pty} =
             Ezagent.BehaviorRegistry.lookup(Ezagent.Entity.Agent, :write)
  end

  test "dispatch against an agent with no PtyServer → :no_pty_server" do
    # Spawn the PTY-capable test Kind (so dispatch resolves) but no PtyServer.
    bare_uri =
      Ezagent.URI.new!(
        "entity://team-alpha/agent/cc_no-pty-#{System.unique_integer([:positive])}"
      )

    {:ok, _kind_pid} = EzagentDomainPty.Test.PtyAgentFixture.spawn(bare_uri)

    assert {:error, :no_pty_server} =
             Invocation.dispatch(%Invocation{
               target: dispatch_target(bare_uri),
               mode: :call,
               args: %{bytes: "x"},
               ctx: admin_ctx()
             })
  end

  test "PubSub output topic broadcasts on chunk arrival", %{agent_uri: agent_uri, pty_pid: pid} do
    Phoenix.PubSub.subscribe(
      EzagentCore.PubSub,
      Ezagent.Domain.Pty.Server.output_topic(agent_uri)
    )

    # Simulate a stdout chunk arrival (the erlexec :stdout message shape).
    send(pid, {:stdout, 0, "hello from pty\n"})

    assert_receive {:pty_output, ^agent_uri, "hello from pty\n"}, 500
  end

  defp pty_slice_state(%{state: state}) when is_map(state), do: state
  defp pty_slice_state(slice), do: slice
end
