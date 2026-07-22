defmodule Ezagent.Session.JoinReturnStatusTest do
  @moduledoc "M-6: a join call reports Phase-A status, never a projected roster."

  use EzagentCore.DataCase, async: false

  alias Ezagent.ActionSet.Session

  test "T16: call join returns granted status without a members field" do
    session = Ezagent.URI.session("join-return-status", :default, "s-#{unique()}")
    member = Ezagent.URI.user("join-return-status", "member-#{unique()}")

    assert {:ok, session_pid} =
             Ezagent.Kind.spawn(Ezagent.Entity.Session, %{
               uri: session,
               owner_uri: Ezagent.Entity.User.admin_uri(),
               behaviors: Ezagent.Entity.Session.behaviors()
             })

    assert {:ok, _row} = Ezagent.Users.create(member, "pw-#{unique()}", [])

    on_exit(fn ->
      if Process.alive?(session_pid) do
        DynamicSupervisor.terminate_child(
          EzagentDomainInstanceMessage.SessionSupervisor,
          session_pid
        )
      end
    end)

    assert {:ok, result, _effects} = Session.handle_join(%{member: member}, ctx(session))
    assert result == %{status: :granted, member: member}
    refute Map.has_key?(result, :members)
  end

  defp ctx(session) do
    admin = Ezagent.Entity.User.admin_uri()

    %{
      self_uri: session,
      caller: admin,
      authenticated_principal: admin,
      transients: %{monitors: %{}},
      read: fn
        :members, _default -> %{}
        :join_cursors, _default -> %{}
        :join_facets, _default -> %{}
        :pending_members, _default -> %{}
        :owner_uri, _default -> admin
        _key, default -> default
      end
    }
  end

  defp unique, do: System.unique_integer([:positive])
end
