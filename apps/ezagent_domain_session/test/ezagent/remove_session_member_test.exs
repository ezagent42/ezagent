defmodule EzagentDomainInstanceMessage.RemoveSessionMemberTest do
  @moduledoc """
  F7 — `remove_session_member/4` resolves the member's `role_name` off the live
  session roster and routes the removal through the orchestrator tool (terminate
  worker + prune routing). A member with no managed `role_name` (e.g. a plain
  user, or any member on a cold/empty roster) is reported `:member_not_managed`
  rather than half-removed via the bare `:session :leave`.
  """
  use ExUnit.Case, async: true

  alias EzagentDomainInstanceMessage, as: Facade

  test "a member that holds no managed role on the (cold) session is not removable" do
    # No Session Kind is alive in this bare unit harness, so `read_members/1`
    # yields an empty roster — there is no managed role to tear down, so the
    # removal reports `:member_not_managed` (never the orphaning bare `:leave`).
    session_uri = Ezagent.URI.session(:system, :default, "f7-remove-probe")
    member_uri = Ezagent.URI.agent("system", "f7-orphan-member")
    caller = Ezagent.Entity.User.admin_uri()

    assert {:error, :member_not_managed} =
             Facade.remove_session_member(session_uri, member_uri, caller, MapSet.new())
  end

  test "the facade exposes remove_session_member/4" do
    assert function_exported?(Facade, :remove_session_member, 4)
  end
end
