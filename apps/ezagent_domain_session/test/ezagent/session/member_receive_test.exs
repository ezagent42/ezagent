defmodule Ezagent.Session.MemberReceiveTest do
  @moduledoc """
  Membership-cap unification A2.1 (spec R1.1 + R1.2 + R2.3) — the shared
  in-handler RECEIVE authorization predicate. Authorizes a fan-out receive iff
  the RECIPIENT holds a real-entity-granted member-cap matching `ctx.caller` (the
  source session), read from the pre-loaded `ctx[:siblings][:identity]` slice.

  Pure unit test: it exercises `authorize/1` directly against a hand-built ctx
  (siblings[:identity] pre-loaded, exactly as `reads_siblings([:identity])`
  injects at dispatch), so there is no Kind spin-up and no deadlock surface.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Capability
  alias Ezagent.Session.MemberReceive

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

  defp uniq, do: System.unique_integer([:positive])

  defp session_uri, do: URI.new!("session://system/default/sess-#{uniq()}")

  # The universal member-cap `cap(:session, Session, :receive, S)` with an
  # explicit `granted_by` — mirrors `MemberCap.member_cap/2` (the at-join grant).
  defp member_cap(session_uri, granted_by) do
    %Capability{
      Capability.cap(
        :session,
        Ezagent.ActionSet.Session,
        :receive,
        session_uri,
        Capability.workspace_of(session_uri)
      )
      | granted_by: granted_by,
        granted_at: DateTime.utc_now()
    }
  end

  # A receive ctx as the runtime injects it: `caller` = the source session,
  # `siblings[:identity]` = the recipient's own pre-loaded identity slice
  # (`%{caps: MapSet}`), which `authorize/1` reads WITHOUT a cross-process call.
  defp receive_ctx(caller: caller, holder: holder, held_caps: held) do
    %{
      caller: caller,
      self_uri: holder,
      siblings: %{identity: %{caps: MapSet.new(held)}}
    }
  end

  test "authorize passes iff the recipient holds a member-cap matching ctx.caller (source session)" do
    session = session_uri()
    owner = URI.new!("entity://system/user/owner-#{uniq()}")
    holder = URI.new!("entity://system/user/holder-#{uniq()}")
    {:ok, authority} = Ezagent.Cap.Authority.open(session, :session)

    cap =
      session
      |> member_cap(owner)
      |> Map.merge(%{grantee_uri: holder})
      |> then(&Ezagent.Cap.Authority.sign(authority, &1))

    license(holder, [cap])
    ctx = receive_ctx(caller: session, holder: holder, held_caps: [cap])

    assert MemberReceive.authorize(ctx) == :ok
  end

  test "authorize denies when the recipient does NOT hold a member-cap over ctx.caller" do
    session = session_uri()
    other_session = session_uri()
    owner = URI.new!("entity://system/user/owner-#{uniq()}")
    holder = URI.new!("entity://system/user/holder-#{uniq()}")

    # Holds a member-cap over a DIFFERENT session — not over `ctx.caller`.
    ctx =
      receive_ctx(caller: session, holder: holder, held_caps: [member_cap(other_session, owner)])

    assert MemberReceive.authorize(ctx) == {:error, :unauthorized}
  end

  test "authorize denies a recipient holding NO caps at all" do
    session = session_uri()
    holder = URI.new!("entity://system/user/holder-#{uniq()}")
    ctx = receive_ctx(caller: session, holder: holder, held_caps: [])

    assert MemberReceive.authorize(ctx) == {:error, :unauthorized}
  end

  test "authorize denies a system-granted (provenance-filtered, K4) member-cap" do
    session = session_uri()
    system_granter = URI.new!("system://chat-router")
    holder = URI.new!("entity://system/user/holder-#{uniq()}")

    # Correct shape, correct instance — but granted_by a system:// principal, so
    # `granted_by_entity?/1` filters it out BEFORE `matches?/2`.
    ctx =
      receive_ctx(
        caller: session,
        holder: holder,
        held_caps: [member_cap(session, system_granter)]
      )

    assert MemberReceive.authorize(ctx) == {:error, :unauthorized}
  end

  test "authorize denies when ctx.caller is nil / not a session URI" do
    owner = URI.new!("entity://system/user/owner-#{uniq()}")
    some_session = session_uri()

    assert MemberReceive.authorize(%{caller: nil, siblings: %{identity: %{caps: MapSet.new()}}}) ==
             {:error, :unauthorized}

    assert MemberReceive.authorize(%{
             caller: :vm_internal,
             siblings: %{identity: %{caps: MapSet.new([member_cap(some_session, owner)])}}
           }) == {:error, :unauthorized}
  end

  test "authorize denies when the identity sibling was not pre-loaded" do
    session = session_uri()
    holder = URI.new!("entity://system/user/holder-#{uniq()}")
    assert MemberReceive.authorize(%{caller: session, self_uri: holder}) == {:error, :unauthorized}

    assert MemberReceive.authorize(%{caller: session, self_uri: holder, siblings: %{}}) ==
             {:error, :unauthorized}
  end

  defp license(holder, caps) do
    Application.put_env(:ezagent_core, EzagentCore.Test.CapAuthorityLoaderStub, %{
      Ezagent.URI.stable_key(holder) => MapSet.new(caps)
    })
  end

end
