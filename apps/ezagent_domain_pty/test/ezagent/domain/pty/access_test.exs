defmodule Ezagent.Domain.Pty.AccessTest do
  @moduledoc """
  The terminal-read gate.

  Before this gate, both world-plugin read exits (the `pty_terminal` component
  state and `WorldLive`'s PubSub subscription) took the agent URI straight from
  the URL and served the live output + scrollback with NO capability check and NO
  workspace check — any authenticated entity could watch any agent's terminal in
  any workspace, including the `claude /login` codes typed into it.

  Allen, 2026-07-14: the terminal belongs to the creator. These pin that.
  """
  use ExUnit.Case, async: true

  alias Ezagent.Domain.Pty.Access, as: PtyAccess

  @agent Ezagent.URI.new!("entity://team-alpha/agent/cc_mine")
  @other Ezagent.URI.new!("entity://team-alpha/agent/cc_someone-elses")
  @creator Ezagent.URI.new!("entity://team-alpha/user/creator")

  # EXACTLY the cap agent creation mints for the creator today. Nothing added.
  defp creator_cap(agent_uri) do
    Ezagent.CreatorGrant.manage_cap(
      :agent,
      agent_uri,
      Ezagent.URI.new!("workspace://team-alpha"),
      @creator
    )
  end

  test "the creator may watch their own agent's terminal — with the cap they already hold" do
    assert PtyAccess.may_read?(@agent, MapSet.new([creator_cap(@agent)]))
  end

  test "admin's genesis cap may watch any terminal" do
    assert PtyAccess.may_read?(@agent, MapSet.new([Ezagent.Capability.admin_genesis_cap()]))
  end

  test "an authenticated user holding NO caps may not watch — this was the hole" do
    refute PtyAccess.may_read?(@agent, MapSet.new())
  end

  test "a manage cap on ANOTHER agent does not open this one" do
    refute PtyAccess.may_read?(@agent, MapSet.new([creator_cap(@other)]))
  end

  test "a Pty-behavior cap does not open the terminal — the authority is Manage" do
    pty_cap = %Ezagent.Capability{
      kind: :agent,
      behavior: Ezagent.ActionSet.Pty,
      action: :any,
      instance: @agent,
      workspace_uri: Ezagent.URI.new!("workspace://team-alpha"),
      granted_by: @creator,
      granted_at: DateTime.utc_now()
    }

    refute PtyAccess.may_read?(@agent, MapSet.new([pty_cap]))
  end

  test "garbage in the caps position is refused, not crashed" do
    refute PtyAccess.may_read?(@agent, nil)
    refute PtyAccess.may_read?(@agent, :not_caps)
  end
end
