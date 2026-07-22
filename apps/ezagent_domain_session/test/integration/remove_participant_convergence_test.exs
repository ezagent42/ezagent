defmodule EzagentDomainInstanceMessage.Integration.RemoveParticipantConvergenceTest do
  @moduledoc """
  F7 PR-A integration — cross-op convergence (SPEC §5.4) of the SHARED
  `Ezagent.Session.Participants.remove_participant/3` entry the CLI and the
  world UI both call.

  Proves the lead's cross-op requirement: removal routes LEAVE-FIRST so the
  `{:member_left}` membership broadcast fires (the surface-agnostic convergence
  signal world_live subscribes to → panel refresh), AND that a remove via the
  shared domain entry (the CLI/UI 同源 path) is reflected in a subsequent
  `list_participants/1` read of the SAME persisted slice the UI renders. So a
  CLI remove live-updates an open UI, and a UI remove shows up in a CLI `list`.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{Invocation, KindRegistry}
  alias Ezagent.ActionSet.Session.Membership
  alias Ezagent.Entity.{Session, User}
  alias Ezagent.Session.Participants
  import Ezagent.Test.CapHelper, only: [signed_action_cap!: 2, signed_required_cap!: 5]

  setup do
    _ =
      EzagentDomainInstanceMessage.SessionCreator.create_session("main", User.admin_uri(),
        template_name: "default"
      )

    :ok
  end

  defmodule NoopServer do
    @moduledoc false
    use GenServer

    @impl true
    def init(uri) do
      :ok = Ezagent.KindRegistry.put_new(uri)
      {:ok, %{}}
    end

    # The Session probes member Kinds (`:ezagent_kind_module` / `:ezagent_get_slice`)
    # during membership ops; answer benignly so teardown doesn't log a crash.
    @impl true
    def handle_call(_msg, _from, state), do: {:reply, :ignore, state}

    @impl true
    def handle_cast(_msg, state), do: {:noreply, state}
  end

  # Operator ctx mirroring the CLI's `operator_ctx/2`: caller + an inline
  # `:remove_participant` cap so the dispatch clears the chokepoint. The handler's
  # identity gate (owner / self / admin) is the real authorization keyed on caller.
  defp op_ctx(%URI{} = caller, %URI{} = session_uri) do
    cap =
      signed_required_cap!(
        session_uri,
        :session,
        Ezagent.ActionSet.Session,
        :remove_participant,
        caller
      )

    %{caller: caller, authenticated_principal: caller, caps: [cap]}
  end

  defp join_member(session_uri, member_uri) do
    target = URI.new!("#{URI.to_string(session_uri)}?action=session.join")
    admin = User.admin_uri()

    :ok =
      Invocation.dispatch(%Invocation{
        origin: :trusted_internal,
        target: target,
        mode: :cast,
        args: %{member: member_uri},
        ctx: %{
          caller: admin,
          authenticated_principal: admin,
          caps: MapSet.new([signed_action_cap!(target, admin)]),
          reply: :ignore
        }
      })

    :ok
  end

  # Create + spawn a CONFIRMED real User (can hold caps) and join it as an
  # OWNER-INVITED member of `session_uri` (admin is the `main` owner): provision
  # the invited-join authority → join under its own authority → mount the
  # participation tier. The resulting member holds the participation tier
  # (:send/:leave) but NOT the owner's `:remove_participant` cap — the exact
  # precondition for the self-leave (§3.3) check.
  defp invited_user_member(session_uri, prefix) do
    # Member in the SAME workspace as the session (`main` is system/…) — else the
    # invited join is `:cross_workspace_denied` (invariant 13).
    member_uri =
      URI.new!("entity://system/user/#{prefix}-#{System.unique_integer([:positive])}")

    {:ok, _row} = Ezagent.Users.create(member_uri, "pw-not-secret-#{System.unique_integer()}", [])
    {:ok, _pid} = Ezagent.SpawnRegistry.spawn(member_uri)

    :ok = Membership.provision_invited_join_authority(session_uri, member_uri, User.admin_uri())

    :ok =
      Invocation.dispatch(%Invocation{
        origin: :trusted_internal,
        target: URI.new!("#{URI.to_string(session_uri)}?action=session.join"),
        mode: :call,
        args: %{member: member_uri},
        ctx: %{
          caller: member_uri,
          authenticated_principal: member_uri,
          caps: Ezagent.Identity.list_caps_for(member_uri),
          reply: {:caller_inbox, self()}
        }
      })
      |> case do
        :ok -> :ok
        {:ok, _} -> :ok
      end

    _ = Membership.mount_participation_caps(session_uri, member_uri)

    member_uri
  end

  test "remove via the shared entry: {:member_left} broadcast fires AND list_participants converges" do
    session_uri = Session.default_uri()
    {:ok, session_pid} = KindRegistry.lookup(session_uri)

    member_uri =
      URI.new!("entity://system/user/conv-#{System.unique_integer([:positive])}")

    {:ok, _member_pid} = GenServer.start(NoopServer, member_uri)

    join_member(session_uri, member_uri)

    # Confirm the member landed (live slice — the UI-rendered source).
    assert member_uri in Participants.list_participants(session_uri)

    # Subscribe to the membership-changes topic — the convergence signal an open
    # UI (world_live) reacts to by refreshing its panel.
    :ok = Phoenix.PubSub.subscribe(EzagentCore.PubSub, "esr:session_membership:changes")

    # Remove via the SHARED domain entry the CLI + UI both call. The admin is the
    # session owner here, so it's authorized at the chokepoint.
    assert {:ok, %{status: :removed, torn_down: :membership_only}} =
             Participants.remove_participant(
               session_uri,
               member_uri,
               op_ctx(User.admin_uri(), session_uri)
             )

    # (1) Convergence signal: the {:member_left} membership broadcast fired
    #     (drives a live UI refresh — leave-FIRST §5.4).
    assert_receive {:session_membership_change, ^session_uri, {:member_left, ^member_uri}}, 2_000

    # (2) State convergence: a subsequent list (what a CLI `list` / the UI panel
    #     reads — the SAME persisted slice) no longer shows the member.
    refute member_uri in Participants.list_participants(session_uri)

    # Sanity: the live slice itself dropped the member (UI source of truth).
    %{state: %{session: %{state: slice}}} = :sys.get_state(session_pid)
    refute Map.has_key?(slice.members, member_uri)
  end

  test "removing a non-member returns {:ok, :already_removed} through real dispatch" do
    session_uri = Session.default_uri()

    not_a_member =
      URI.new!("entity://system/user/ghost-#{System.unique_integer([:positive])}")

    refute not_a_member in Participants.list_participants(session_uri)

    # Through the SHARED entry (real dispatch + InterfaceValidator), the admin
    # owner removing a non-member is an idempotent no-op.
    assert {:ok, :already_removed} =
             Participants.remove_participant(
               session_uri,
               not_a_member,
               op_ctx(User.admin_uri(), session_uri)
             )
  end

  test "self-leave through the shared entry works without the owner cap" do
    session_uri = Session.default_uri()
    member_uri = invited_user_member(session_uri, "selfleave")

    assert member_uri in Participants.list_participants(session_uri)

    # The member holds the participation tier but NOT the owner :remove_participant
    # cap — confirm it cannot be removed by ANOTHER non-owner (gate holds) ...
    stranger = invited_user_member(session_uri, "stranger")

    assert {:error, :unauthorized} =
             Participants.remove_participant(
               session_uri,
               member_uri,
               op_ctx(stranger, session_uri)
             )

    # ... yet caller == participant (self-leave) is authorized: the shared entry
    # provisions the JIT self-leave authority so the dispatch clears the
    # chokepoint and the handler's `caller == participant` gate passes (§3.3).
    assert {:ok, %{status: :removed}} =
             Participants.remove_participant(session_uri, member_uri, %{
               caller: member_uri,
               authenticated_principal: member_uri
             })

    refute member_uri in Participants.list_participants(session_uri)
  end
end
