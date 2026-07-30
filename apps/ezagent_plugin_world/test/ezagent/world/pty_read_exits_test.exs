defmodule Ezagent.World.PtyReadExitsTest do
  @moduledoc """
  The REGRESSION tests for the ungated-PTY-read hole.

  `Ezagent.Domain.Pty.AccessTest` proves the PREDICATE is right; these prove the
  EXITS actually consult it. There is more than one exit and they are
  independent — the first version of this fix gated the `/identities/agents/:uri/
  terminal` route and left the in-conversation `session.pty.open` path wide open,
  which is the same hole with a different entry.

  Remove either gate and the corresponding test goes red.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.World.IdentityData

  @agent Ezagent.URI.new!("entity://team-alpha/agent/cc_gate-probe")
  @creator Ezagent.URI.new!("entity://team-alpha/user/creator")

  setup do
    previous = install_loader()
    on_exit(fn -> Application.put_env(:ezagent_core, Ezagent.Cap, previous) end)
    :ok
  end

  defp route,
    do: %{
      component: "pty_terminal",
      title: "Terminal",
      path: "/identities/agents/x/terminal",
      entity_uri: @agent
    }

  defp state_with(caps) do
    IdentityData.state_for(route(), %{
      workspace_uri: Ezagent.URI.new!("workspace://team-alpha"),
      caller_uri: @creator,
      caller_caps: caps
    })
  end

  test "a viewer with NO cap for this agent gets NO buffer and NO liveness" do
    license([:principal_is_live])
    state = state_with(MapSet.new())

    refute state["pty_authorized"]
    assert state["pty_initial_buffer"] == ""
    assert state["pty_alive"] == false
    assert state["pty_phase"] == "unknown"
  end

  test "the creator's existing manage cap opens it" do
    cap = signed_creator_cap()
    license([cap])

    assert state_with(MapSet.new([cap]))["pty_authorized"]
  end

  defp signed_creator_cap do
    {:ok, authority} = Ezagent.Cap.Authority.open(@agent, :agent)

    Ezagent.CreatorGrant.manage_cap(
      :agent,
      @agent,
      Ezagent.URI.new!("workspace://team-alpha"),
      @creator
    )
    |> Map.put(:grantee_uri, @creator)
    |> then(&Ezagent.Cap.Authority.sign(authority, &1))
  end

  defp install_loader do
    previous = Application.get_env(:ezagent_core, Ezagent.Cap, [])

    Application.put_env(
      :ezagent_core,
      Ezagent.Cap,
      Keyword.put(previous, :authority_loader, EzagentCore.Test.CapAuthorityLoaderStub)
    )

    previous
  end

  defp license(caps) do
    Application.put_env(:ezagent_core, EzagentCore.Test.CapAuthorityLoaderStub, %{
      Ezagent.URI.stable_key(@creator) => MapSet.new(caps)
    })
  end
end

defmodule Ezagent.World.PtyConversationExitTest do
  @moduledoc """
  Exit: the in-conversation `session.pty.open` client event.

  `ConversationActions.switch_to_pty/3` takes the agent URI from CLIENT input and
  subscribes to that agent's live PTY output. Ungated, any authenticated user
  could open any agent's terminal in any workspace from inside a conversation —
  the same hole as the terminal route, through a different door.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.World.ConversationActions

  @agent Ezagent.URI.new!("entity://team-alpha/agent/cc_conv-exit-probe")
  @session Ezagent.URI.new!("session://team-alpha/default/conv-exit-probe")
  @creator Ezagent.URI.new!("entity://team-alpha/user/creator")

  setup do
    previous = Application.get_env(:ezagent_core, Ezagent.Cap, [])

    Application.put_env(
      :ezagent_core,
      Ezagent.Cap,
      Keyword.put(previous, :authority_loader, EzagentCore.Test.CapAuthorityLoaderStub)
    )

    on_exit(fn -> Application.put_env(:ezagent_core, Ezagent.Cap, previous) end)
    :ok
  end

  defp socket_with(caps) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        current_caps: caps,
        current_entity_uri: @creator,
        last_dispatch_status: "idle"
      }
    }
  end

  defp creator_cap do
    {:ok, authority} = Ezagent.Cap.Authority.open(@agent, :agent)

    cap =
      Ezagent.CreatorGrant.manage_cap(
        :agent,
        @agent,
        Ezagent.URI.new!("workspace://team-alpha"),
        @creator
      )
      |> Map.put(:grantee_uri, @creator)
      |> then(&Ezagent.Cap.Authority.sign(authority, &1))

    Application.put_env(:ezagent_core, EzagentCore.Test.CapAuthorityLoaderStub, %{
      Ezagent.URI.stable_key(@creator) => MapSet.new([cap]),
      # `switch_to_pty` (#1576) self-dispatches a `reconcile_cascade` command
      # AS the agent once it is spawned live (`ConfigEvolve.activate/2`'s
      # boot reconcile). `Ezagent.Cap.Authorize.authorize/3`'s principal gate
      # is independent of the presented candidate caps — it is satisfied
      # purely by `read_held_caps(holder) != []` (see
      # `Ezagent.Cap.Authorize.principal_current?/1`) — so a placeholder
      # non-empty entry for the agent's own identity is enough to keep its
      # self-dispatch from reading as a revoked principal under this
      # narrowly-scoped stub. The reconcile's own caps are minted fresh
      # (properly signed) via `Ezagent.Cap.issue/3`, so this placeholder
      # never substitutes for a real capability check.
      Ezagent.URI.stable_key(@agent) => MapSet.new([:test_principal_marker]),
      # `ensure_canonical_admin_current/1` (Ezagent.Cap #195 canonical-admin
      # bootstrap) lazily starts the system/admin Kind the first time an
      # `{:admin, admin}`-authorized `Cap.issue/3` runs — here, from the
      # agent's own boot reconcile minting its self-caps as admin. A live
      # admin Kind normally proves its own currency via a freshly-minted
      # `:identity`-slice self-license (see that function's moduledoc), but
      # this stub is static and knows nothing about that — so admin's own
      # principal gate needs the same placeholder treatment.
      Ezagent.URI.stable_key(Ezagent.URI.user(:system, :admin)) =>
        MapSet.new([:test_principal_marker])
    })

    cap
  end

  test "a viewer with NO cap is refused and subscribes to NOTHING" do
    {:noreply, socket} =
      ConversationActions.switch_to_pty(
        socket_with(MapSet.new()),
        @session,
        URI.to_string(@agent)
      )

    assert socket.assigns.last_dispatch_status == "error:unauthorized"

    # The decisive part: no subscription happened, so PTY output cannot reach
    # this process even if the agent is chattering.
    Phoenix.PubSub.broadcast(
      EzagentCore.PubSub,
      Ezagent.Domain.Pty.Server.output_topic(@agent),
      {:pty_output, @agent, "secret"}
    )

    refute_receive {:pty_output, _, _}, 100
  end

  test "a manage-cap holder cannot open an unrelated agent through a session PTY action" do
    cap = creator_cap()
    # Actor-extraction C1: switch_to_pty re-derives caps FRESH via
    # PresenterCaps.load → EntityCaps.load(@creator); the creator must DURABLY
    # hold the signed manage cap (the spawn mints the current self-license).
    {:ok, _pid} =
      Ezagent.Kind.spawn(Ezagent.Entity.User, %{uri: @creator, initial_caps: [cap]})

    on_exit(fn -> Ezagent.Kind.terminate(@creator) end)

    # #1576 made `switch_to_pty` demand-revive the agent via
    # `Agent.ensure_deliverable/1` (LocalRuntime.ensure_live/1) before it
    # subscribes — the fix for a session retaining an agent membership
    # across a node restart while the agent's subprocess is cold. That
    # check refuses to materialize a Kind that was never durably created
    # (`{:error, :not_created}`), and `@agent` here is a synthetic URI with
    # no snapshot row. Spawn it live first (same pattern as
    # `Ezagent.Domain.Agent`'s own `ensure_deliverable` coverage in
    # apps/ezagent_domain_agent/test/ezagent/domain/agent_test.exs) so
    # `ensure_live` finds it already registered and short-circuits to
    # `{:ok, :live}` — this test is about the manage-cap authorization gate
    # reaching the subscribe, not about cold-agent rehydration.
    #
    # `push_pty_view/2` (also new in #1576) reads `Agent.lifecycle_status/1`,
    # which resolves the agent's flavor. A bare spawn carries no launch
    # flavor attribute, so without this the resolver falls through to a
    # LIVE `:sandbox` slice read on the Kind — an authenticated round trip
    # this narrowly-stubbed test environment cannot satisfy. Stamp the
    # launch flavor up front via the same public API a real template class
    # uses (`Ezagent.AgentFlavorAttributes.put/2`) so resolution is a plain
    # ETS hit and never touches the live Kind.
    Ezagent.AgentFlavorAttributes.put(@agent, "cc")
    {:ok, _agent_pid} = Ezagent.Kind.spawn(Ezagent.Entity.Agent, %{uri: @agent})

    on_exit(fn ->
      Ezagent.Kind.terminate(@agent)
      Ezagent.AgentFlavorAttributes.delete(@agent)
    end)

    {:noreply, socket} =
      ConversationActions.handle_dispatch(
        socket_with(MapSet.new([cap]))
        |> Phoenix.Component.assign(:current_session_uri, @session),
        "session.pty.open",
        %{"session_uri" => URI.to_string(@session), "agent" => URI.to_string(@agent)}
      )

    assert socket.assigns.last_dispatch_status == "error:session_pty_target_unrelated"

    Phoenix.PubSub.broadcast(
      EzagentCore.PubSub,
      Ezagent.Domain.Pty.Server.output_topic(@agent),
      {:pty_output, @agent, "mine"}
    )

    refute_receive {:pty_output, _, "mine"}, 100
  end
end

defmodule Ezagent.World.PtyChunkBindingTest do
  @moduledoc """
  PTY subscriptions accumulate and are never torn down: open agent A's terminal,
  then agent B's, and the LV is subscribed to both. Forwarding every chunk the
  process receives bled A's output into B's on-screen terminal, and kept
  streaming a terminal the viewer had navigated away from — including after
  their authority over it changed.

  Chunks must be bound to the agent actually on screen. Asserted on the socket
  the handler returns (untouched vs. mutated) rather than on LiveView's internal
  event buffer, so this does not break on a LiveView upgrade.
  """
  use EzagentCore.DataCase, async: false

  alias EzagentPluginWorld.WorldLive

  @a "entity://team-alpha/agent/cc_alpha"
  @b "entity://team-alpha/agent/cc_beta"

  defp socket_showing(agent_uri_str) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        world_state: %{"component" => "pty_terminal", "agent_uri" => agent_uri_str}
      }
    }
  end

  test "a chunk from the agent on screen reaches the browser" do
    input = socket_showing(@a)
    {:noreply, out} = WorldLive.handle_info({:pty_output, Ezagent.URI.new!(@a), "mine"}, input)

    refute out == input, "the on-screen agent's chunk must be pushed"
  end

  test "a chunk from a DIFFERENT agent is dropped — no cross-terminal bleed" do
    input = socket_showing(@a)

    {:noreply, out} =
      WorldLive.handle_info({:pty_output, Ezagent.URI.new!(@b), "someone else's"}, input)

    assert out == input, "another agent's chunk must not reach this terminal"
  end

  test "a phase event from a DIFFERENT agent does not rewrite this terminal's phase" do
    input = socket_showing(@a)

    {:noreply, out} =
      WorldLive.handle_info({:pty_phase, Ezagent.URI.new!(@b), :dead, %{}}, input)

    assert out == input
  end
end
