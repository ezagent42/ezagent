defmodule Ezagent.Domain.Pty.AccessTest do
  @moduledoc """
  F-4 terminal-read gate: a target-signed Manage cap authorizes only while the
  target generation and authenticated holder are both current.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Cap.Authority
  alias Ezagent.Capability
  alias Ezagent.Domain.Pty.Access, as: PtyAccess

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

  test "the creator may watch their own agent with its current target-signed Manage cap" do
    holder = unique_user("creator")
    agent = unique_agent("mine")
    cap = signed_manage_cap(agent, holder)
    license(holder, [cap])

    assert PtyAccess.may_read?(holder, agent, MapSet.new([cap]))
  end

  test "a bumped agent generation immediately closes PTY read access" do
    holder = unique_user("creator")
    agent = unique_agent("bumped")
    cap = signed_manage_cap(agent, holder)
    license(holder, [cap])

    assert PtyAccess.may_read?(holder, agent, [cap])
    assert {:ok, _} = Authority.regenesis(agent, :agent, admin())
    refute PtyAccess.may_read?(holder, agent, [cap])
  end

  test "an authenticated holder with no caps may not watch" do
    holder = unique_user("empty")
    agent = unique_agent("closed")
    license(holder, [:principal_is_live])

    refute PtyAccess.may_read?(holder, agent, MapSet.new())
  end

  test "a Manage cap on another agent does not open this one" do
    holder = unique_user("creator")
    agent = unique_agent("mine")
    other = unique_agent("other")
    cap = signed_manage_cap(other, holder)
    license(holder, [cap])

    refute PtyAccess.may_read?(holder, agent, [cap])
  end

  test "a target-signed Pty-behavior cap does not substitute for Manage" do
    holder = unique_user("creator")
    agent = unique_agent("wrong-behavior")
    {:ok, authority} = Authority.open(agent, :agent)

    cap =
      %Capability{
        kind: :agent,
        behavior: Ezagent.ActionSet.Pty,
        action: :any,
        instance: agent,
        workspace_uri: Capability.workspace_of(agent),
        granted_by: holder,
        granted_at: DateTime.utc_now(),
        grantee_uri: holder
      }
      |> then(&Authority.sign(authority, &1))

    license(holder, [cap])
    refute PtyAccess.may_read?(holder, agent, [cap])
  end

  test "garbage in the holder or caps position is refused, not crashed" do
    agent = unique_agent("garbage")
    holder = unique_user("creator")

    refute PtyAccess.may_read?(nil, agent, [])
    refute PtyAccess.may_read?(holder, agent, nil)
    refute PtyAccess.may_read?(holder, agent, :not_caps)
  end

  defp signed_manage_cap(agent, holder) do
    {:ok, authority} = Authority.open(agent, :agent)

    cap =
      Ezagent.CreatorGrant.manage_cap(
        :agent,
        agent,
        Capability.workspace_of(agent),
        holder
      )

    cap
    |> Map.put(:grantee_uri, holder)
    |> then(&Authority.sign(authority, &1))
  end

  defp license(holder, caps) do
    Application.put_env(:ezagent_core, EzagentCore.Test.CapAuthorityLoaderStub, %{
      Ezagent.URI.stable_key(holder) => MapSet.new(caps)
    })
  end

  defp unique_agent(suffix) do
    Ezagent.URI.new!(
      "entity://team-alpha/agent/f4-#{suffix}-#{System.unique_integer([:positive])}"
    )
  end

  defp unique_user(suffix) do
    Ezagent.URI.new!(
      "entity://team-alpha/user/f4-#{suffix}-#{System.unique_integer([:positive])}"
    )
  end

  defp admin, do: Ezagent.URI.user(:system, :admin)
end
