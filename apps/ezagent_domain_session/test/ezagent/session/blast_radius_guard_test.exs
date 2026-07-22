defmodule Ezagent.Session.BlastRadiusGuardTest do
  @moduledoc """
  Membership-cap unification A2.6 — blast-radius regression guards (spec tests 6,
  12). The R1.1 crux is that the `:members` slice stays a fast O(1) delivery
  ROSTER: the send fan-out must NOT be "simplified" into a per-message reverse
  cap scan, and the roster's shape (the UI-roster / read source) is unchanged.
  """

  use ExUnit.Case, async: true

  @session_app_root Path.expand("../../..", __DIR__)

  defp read_lib(rel), do: File.read!(Path.join(@session_app_root, rel))

  # test 6 — the crux/perf shape: the send fan-out derives recipients from the
  # O(1) `:members` roster read (via the Resolver's `$session_members`), never a
  # reverse "who holds a member-cap over S" workspace scan per message. R1.1: a
  # stale roster costs a wasted dispatch that then FAILS authz at the recipient —
  # never an O(N) reverse query on the hot path.
  test "delivery fan-out reads the O(1) roster, NO reverse cap scan per message (test 6)" do
    send_src = read_lib("lib/ezagent/behavior/session.ex")
    delivery_src = read_lib("lib/ezagent/behavior/session/delivery.ex")

    # The O(1) roster read is preserved.
    assert send_src =~ "ctx[:read].(:members"

    # No per-message reverse cap scan on the send/fan-out path (the shape that
    # would turn every message into an O(members) or O(workspace) cap query).
    refute send_src =~ "list_in_workspace",
           "the send path must not enumerate the workspace per message (reverse scan)"

    refute delivery_src =~ "read_entity_caps",
           "delivery fan-out must not reverse-scan held caps per recipient — the " <>
             "recipient authorizes on its OWN pre-loaded :identity sibling in-handler"
  end

  # test 12 — the roster projection SHAPE is unchanged: `:members` remains a
  # `member_uri => meta` map (the UI-roster + read-authz source), so nothing that
  # renders/reads the roster regressed when authority moved to the held cap.
  test "the :members roster keeps its `member_uri => meta` shape (test 12)" do
    slice = Ezagent.ActionSet.Session.init_slice(%{}).state

    assert is_map(slice.members), ":members must remain a map (roster projection)"
    assert Map.has_key?(slice, :owner_uri)
    assert Map.has_key?(slice, :last_seen)

    # The socialware read predicate is still callable over a roster-shaped slice.
    chat = %{owner_uri: nil, members: %{}}

    assert {:error, :unauthorized} =
             Ezagent.Session.Membership.authorize(chat, nil, nil, nil)
  end
end
