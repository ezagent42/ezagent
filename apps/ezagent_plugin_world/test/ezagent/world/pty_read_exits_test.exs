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
      Ezagent.URI.stable_key(@creator) => MapSet.new([cap])
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

  test "the creator's existing manage cap opens it and subscribes" do
    cap = creator_cap()
    # Actor-extraction C1: switch_to_pty re-derives caps FRESH via
    # PresenterCaps.load → EntityCaps.load(@creator); the creator must DURABLY
    # hold the signed manage cap (the spawn mints the current self-license).
    {:ok, _pid} =
      Ezagent.Kind.spawn(Ezagent.Entity.User, %{uri: @creator, initial_caps: [cap]})

    on_exit(fn -> Ezagent.Kind.terminate(@creator) end)

    {:noreply, socket} =
      ConversationActions.switch_to_pty(
        socket_with(MapSet.new([cap])),
        @session,
        URI.to_string(@agent)
      )

    refute socket.assigns[:last_dispatch_status] == "error:unauthorized"

    Phoenix.PubSub.broadcast(
      EzagentCore.PubSub,
      Ezagent.Domain.Pty.Server.output_topic(@agent),
      {:pty_output, @agent, "mine"}
    )

    assert_receive {:pty_output, _, "mine"}, 500
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
