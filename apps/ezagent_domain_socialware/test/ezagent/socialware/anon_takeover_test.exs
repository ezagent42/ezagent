defmodule Ezagent.Socialware.AnonTakeoverTest do
  @moduledoc """
  #154 spec 甲-5 — anon→login takeover (route B), the dispatchable mechanism.

  A CONFIRMED user takes over an anonymous user's session footprint
  (`Ezagent.Socialware.AnonTakeover.takeover/3`): the confirmed user joins the
  session (confirmed tier), the anon's membership + read markers transfer to the
  confirmed user, and the anon is retired (`Users.delete` + `AnonBinding.delete`).

  Proven end-to-end against the REAL Session Kind + real dispatch:

    * happy path — footprint transferred, anon retired, confirmed user is a live
      member holding the confirmed-tier participation caps;
    * fail-closed — a non-confirmed caller, a session-mismatched binding, and a
      second (post-retire) call are all rejected without mutating state.

  The authority model is cookie-possession (the `AnonBinding` row) + `confirmed?`
  + the orchestrator's inline `:takeover` cap; NO `system://` principal.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Capability
  alias Ezagent.Entity.{Session, SessionTemplate, User}
  alias Ezagent.KindRegistry
  alias Ezagent.Session.ReadMarker
  alias Ezagent.Socialware.{AnonBinding, AnonTakeover, AnonUser}

  setup do
    # Spawned Session / User Kinds run in their own processes — share sandbox.
    Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, {:shared, self()})
    :ok
  end

  @workspace "team-alpha"
  @owner_default Ezagent.URI.new!("entity://team-alpha/user/takeover-owner")

  # ----- fixtures ------------------------------------------------------------

  defp public_session(owner_uri \\ @owner_default) do
    u = System.unique_integer([:positive])

    {:ok, tmpl_uri} =
      SessionTemplate.persist_version_as_system(
        %{name: "takeover-tmpl-#{u}", public_view: true},
        @workspace
      )

    session_uri = Ezagent.URI.new!("session://#{@workspace}/default/takeover-#{u}")

    spawn_opts = %{uri: session_uri, behaviors: Session.socialware_behaviors()}
    spawn_opts = if owner_uri, do: Map.put(spawn_opts, :owner_uri, owner_uri), else: spawn_opts

    {:ok, _pid} = Ezagent.Kind.spawn(Session, spawn_opts)
    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, Capability.workspace_of(session_uri))

    {:ok, _} =
      Ezagent.Behavior.Session.ConfigActions.system_set_working_copy(session_uri, %{
        session_template_uri: tmpl_uri
      })

    on_exit(fn -> terminate(Session, session_uri) end)
    session_uri
  end

  defp spawn_user_kind(uri) do
    {:ok, _pid} =
      Ezagent.Kind.spawn(User, %{uri: uri, initial_caps: User.initial_caps_for_spawn(uri)})

    on_exit(fn -> terminate(User, uri) end)
    :ok
  end

  defp terminate(kind, uri) do
    case KindRegistry.lookup(uri) do
      {:ok, pid} ->
        sup =
          case kind do
            Session -> EzagentDomainInstanceMessage.SessionSupervisor
            User -> EzagentDomainIdentity.Application.UserSupervisor
          end

        DynamicSupervisor.terminate_child(sup, pid)

      :error ->
        :ok
    end
  end

  # Mint a public-view anon, spawn it, join it, seed an AnonBinding row + a read
  # marker (the footprint to be transferred). Returns the anon URI + seed msg.
  defp seeded_anon(session) do
    {:ok, anon} = AnonUser.mint_for_public_session(session)
    :ok = spawn_user_kind(anon)

    # The anon joins via production dispatch (caller = anon, its own join cap).
    {:ok, _} = join_as_self(session, anon)

    # The controller's first-open touch: the cookie→entity binding row.
    {:ok, _} = AnonBinding.touch(anon, session, DateTime.utc_now())

    msg = insert_message(session, anon)
    assert {:ok, :updated} = ReadMarker.mark(session, anon, msg, :read)

    {anon, msg}
  end

  # A confirmed (login) user. Workspace string MUST be the hyphenated
  # "team-alpha" (matching the session URI) — `Ezagent.URI.entity(:team_alpha,
  # …)` yields the UNDERSCORE form, which the dispatch workspace-isolation check
  # treats as a different workspace (cross_workspace_denied).
  defp confirmed_user(name) do
    uri = Ezagent.URI.new!("entity://#{@workspace}/user/#{name}")
    {:ok, _} = Ezagent.Users.create(uri, "pw-#{name}", [])
    :ok = spawn_user_kind(uri)
    uri
  end

  defp join_as_self(session_uri, anon_uri) do
    target = Ezagent.URI.new!("#{URI.to_string(session_uri)}?action=session.join")

    Ezagent.Invocation.dispatch(%Ezagent.Invocation{
      target: target,
      mode: :call,
      args: %{member: anon_uri},
      # caller = the anon itself, NO ctx.caps — it joins under its own minted cap.
      ctx: %{caller: anon_uri, reply: :ignore}
    })
  end

  defp insert_message(session_uri, sender) do
    msg_uri = "msg://#{System.unique_integer([:positive])}"

    EzagentCore.Repo.insert_all("messages", [
      %{
        id: msg_uri,
        workspace_uri: URI.to_string(Capability.workspace_of(session_uri)),
        session_uri: URI.to_string(session_uri),
        sender: URI.to_string(sender),
        mentions: Jason.encode!([]),
        body: Jason.encode!(%{text: "hi", attachments: []}),
        ref_id: nil,
        inserted_at: DateTime.utc_now()
      }
    ])

    EzagentCore.Repo.insert_all("message_routings", [
      %{message_id: msg_uri, session_uri: URI.to_string(session_uri), inserted_at: DateTime.utc_now()}
    ])

    msg_uri
  end

  defp session_members(session_uri) do
    {:ok, pid} = KindRegistry.lookup(session_uri)
    state = :sys.get_state(pid, 1_000)
    state.state.session.state.members
  end

  # ----- happy path ----------------------------------------------------------

  describe "takeover/3 — footprint transfer + anon retire" do
    test "confirmed user takes over the anon's footprint; anon retired" do
      session = public_session()
      {anon, msg} = seeded_anon(session)
      confirmed = confirmed_user("takeover-alice-#{System.unique_integer([:positive])}")

      # Pre: anon is a member, confirmed user is not.
      assert Map.has_key?(session_members(session), anon)
      refute Map.has_key?(session_members(session), confirmed)

      assert {:ok, %{members: members}} = AnonTakeover.takeover(anon, confirmed, session)

      # Confirmed user is a member; the anon is gone.
      members_map = session_members(session)
      assert Map.has_key?(members_map, confirmed)
      refute Map.has_key?(members_map, anon)
      assert confirmed in members
      refute anon in members

      # Footprint: the anon's read marker now belongs to the confirmed user.
      assert ReadMarker.last_read(session, confirmed, :read) == msg
      assert ReadMarker.last_read(session, anon, :read) == nil

      # Confirmed-tier participation caps mounted (send + leave + subscribe_from).
      held = Ezagent.Identity.list_caps_for(confirmed)
      assert authorizes?(held, Ezagent.Behavior.Session, :send, session)
      assert authorizes?(held, Ezagent.Behavior.Session, :leave, session)
      assert authorizes?(held, Ezagent.Behavior.Publisher.SessionImpl, :subscribe_from, session)

      # Anon retired: users row gone, binding gone.
      assert is_nil(Ezagent.Users.get_by_uri(anon))
      assert is_nil(AnonBinding.get(anon))
    end
  end

  # ----- fail closed ---------------------------------------------------------

  describe "takeover/3 — fail closed" do
    test "a NON-confirmed caller is rejected" do
      session = public_session()
      {anon, _msg} = seeded_anon(session)

      # A second anon (unconfirmed) tries to take over the first.
      attacker = Ezagent.URI.entity(:team_alpha, :user, "anon-attacker")
      {:ok, _} = Ezagent.Users.create_read_only(attacker, [])
      :ok = spawn_user_kind(attacker)

      assert {:error, :not_confirmed} = AnonTakeover.takeover(anon, attacker, session)

      # State untouched — anon still a member + still exists.
      assert Map.has_key?(session_members(session), anon)
      refute is_nil(Ezagent.Users.get_by_uri(anon))
    end

    test "a binding whose session != the target → :session_mismatch" do
      session_a = public_session()
      session_b = public_session(Ezagent.URI.entity(:team_alpha, :user, "takeover-owner-b"))
      {anon_a, _msg} = seeded_anon(session_a)
      confirmed = confirmed_user("takeover-bob-#{System.unique_integer([:positive])}")

      # anon_a's binding points at session_a, but we name session_b.
      assert {:error, :session_mismatch} = AnonTakeover.takeover(anon_a, confirmed, session_b)

      refute is_nil(AnonBinding.get(anon_a))
    end

    test "second takeover after retire → :no_anon_binding (idempotent)" do
      session = public_session()
      {anon, _msg} = seeded_anon(session)
      confirmed = confirmed_user("takeover-carol-#{System.unique_integer([:positive])}")

      assert {:ok, _} = AnonTakeover.takeover(anon, confirmed, session)
      assert {:error, :no_anon_binding} = AnonTakeover.takeover(anon, confirmed, session)
    end

    test "an anon with no binding row at all → :no_anon_binding" do
      session = public_session()
      {:ok, anon} = AnonUser.mint_for_public_session(session)
      confirmed = confirmed_user("takeover-dave-#{System.unique_integer([:positive])}")

      # No AnonBinding.touch — no binding row.
      assert {:error, :no_anon_binding} = AnonTakeover.takeover(anon, confirmed, session)
    end
  end

  # ----- helpers -------------------------------------------------------------

  defp authorizes?(held, behavior, action, session_uri) do
    needed = %{
      kind: :session,
      behavior: behavior,
      action: action,
      instance: Ezagent.URI.instance(session_uri),
      workspace_uri: Capability.workspace_of(session_uri)
    }

    held
    |> caps_list()
    |> Enum.any?(fn
      %Capability{} = cap -> Capability.matches?(cap, needed)
      _ -> false
    end)
  end

  defp caps_list(caps) when is_list(caps), do: caps
  defp caps_list(%MapSet{} = caps), do: MapSet.to_list(caps)
  defp caps_list(caps), do: List.wrap(caps)
end
