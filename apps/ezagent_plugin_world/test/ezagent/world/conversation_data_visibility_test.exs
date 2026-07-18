defmodule Ezagent.World.ConversationDataVisibilityTest do
  @moduledoc """
  The world conversation read plane, post read-plane-authz consolidation.

  Two guarantees, both driven through `ConversationData.state_for/2` +
  `load_older/4` (the stable presenter API):

    * **authz (the security fix):** a NON-member `?session=<uri>` deep-link is
      DENIED — no messages, no roster, `access_denied: true` — on BOTH the
      initial read AND `load_older` pagination. Before consolidation these
      leaked the conversation.
    * **row-policy:** for an AUTHORIZED caller, `:internal` messages are hidden
      unless the caller HOLDS the session `:read_unfiltered` cap (sourced live
      by the `SessionReads` chokepoint, not the passed socket caps).
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.{Capability, KindRegistry, Message, MessageStore}
  alias Ezagent.Entity.{Session, User}
  alias Ezagent.Test.CapHelper
  alias Ezagent.World.ConversationData

  @workspace_uri URI.new!("workspace://team-alpha")
  @stranger URI.new!("entity://team-alpha/user/deep-linker")

  # ----- fixtures --------------------------------------------------------

  defp spawn_owned_session(owner_uri) do
    session_uri =
      Ezagent.URI.new!("session://team-alpha/default/p8a-#{System.unique_integer([:positive])}")

    {:ok, _pid} =
      Ezagent.Kind.spawn(Session, %{
        uri: session_uri,
        owner_uri: owner_uri,
        behaviors: Ezagent.Entity.Session.behaviors()
      })

    :ok = Ezagent.WorkspaceRegistry.bind(session_uri, @workspace_uri)

    on_exit(fn ->
      case KindRegistry.lookup(session_uri) do
        {:ok, pid} ->
          DynamicSupervisor.terminate_child(EzagentDomainInstanceMessage.SessionSupervisor, pid)

        :error ->
          :ok
      end
    end)

    session_uri
  end

  defp spawn_user(%URI{} = user_uri, caps) do
    {:ok, _pid} = Ezagent.Kind.spawn(User, %{uri: user_uri, initial_caps: caps})

    on_exit(fn ->
      case KindRegistry.lookup(user_uri) do
        {:ok, pid} ->
          DynamicSupervisor.terminate_child(EzagentDomainIdentity.Application.UserSupervisor, pid)

        :error ->
          :ok
      end
    end)

    :ok
  end

  defp write(session_uri, text, opts) do
    message = Message.new(@stranger, %{text: text, attachments: []}, opts)
    assert {:ok, written} = MessageStore.write(message, session_uri)
    written
  end

  defp state_for(session_uri, caller) do
    ConversationData.state_for(session_uri, %{
      caller_uri: caller,
      caller_caps: MapSet.new(),
      workspace_uri: @workspace_uri,
      sessions: []
    })
  end

  defp state_texts(session_uri, caller) do
    session_uri |> state_for(caller) |> Map.fetch!("messages") |> Enum.map(&Map.fetch!(&1, "text"))
  end

  defp read_unfiltered_cap(session_uri) do
    Capability.cap(
      :session,
      Ezagent.ActionSet.Session,
      :read_unfiltered,
      session_uri,
      @workspace_uri
    )
  end

  # ----- authz: the deep-link info-disclosure is closed ------------------

  describe "a non-member deep-link is DENIED (fail-loud, no content leak)" do
    test "initial read: state_for returns access_denied + no messages/roster" do
      owner = URI.new!("entity://team-alpha/user/owner-a")
      session_uri = spawn_owned_session(owner)
      write(session_uri, "members-only", visibility: :external_visible)

      state = state_for(session_uri, @stranger)

      # The message + member CONTENT is denied (the disclosure this PR closes).
      # The `views` tab set is independently cap-gated and out of scope here.
      assert state["access_denied"] == true
      assert state["messages"] == []
      assert state["members"] == []
      assert state["human_role_slots"] == []
      assert state["installed_socialwares"] == []
      assert state["invite_candidates"] == []
    end

    test "pagination: load_older for a non-member yields an empty page" do
      owner = URI.new!("entity://team-alpha/user/owner-b")
      session_uri = spawn_owned_session(owner)
      write(session_uri, "members-only", visibility: :external_visible)

      cursor = DateTime.utc_now() |> DateTime.to_iso8601()
      viewer_ctx = %{user_can_fix: false, fix_owner_display_name: nil}

      assert {[], nil} = ConversationData.load_older(session_uri, @stranger, cursor, viewer_ctx)
    end
  end

  # ----- row-policy: preserved for an AUTHORIZED caller ------------------

  describe "row-policy (:read_unfiltered) for an authorized caller" do
    test "conversation state hides internal messages without the cap" do
      owner = URI.new!("entity://team-alpha/user/owner-c")
      session_uri = spawn_owned_session(owner)
      write(session_uri, "public", visibility: :external_visible)
      write(session_uri, "internal", visibility: :internal)

      # The owner is authorized (owner-predicate) but holds no :read_unfiltered
      # cap → the internal message is filtered out.
      assert state_texts(session_uri, owner) == ["public"]
    end

    test "conversation state shows internal messages WITH the signed cap" do
      internal_reader =
        URI.new!("entity://team-alpha/user/owner-unfiltered-#{System.unique_integer([:positive])}")

      session_uri = spawn_owned_session(internal_reader)
      cap = CapHelper.signed_cap!(session_uri, internal_reader, read_unfiltered_cap(session_uri))
      :ok = spawn_user(internal_reader, [cap])

      write(session_uri, "public", visibility: :external_visible)
      write(session_uri, "internal", visibility: :internal)

      assert Enum.sort(state_texts(session_uri, internal_reader)) == ["internal", "public"]
    end

    test "load_older hides internal messages without the cap (authorized member)" do
      owner = URI.new!("entity://team-alpha/user/owner-d")
      session_uri = spawn_owned_session(owner)
      base = ~U[2026-06-28 00:00:00.000000Z]
      write(session_uri, "public-old", inserted_at: DateTime.add(base, 1, :second))

      write(session_uri, "internal-old",
        inserted_at: DateTime.add(base, 2, :second),
        visibility: :internal
      )

      write(session_uri, "public-new", inserted_at: DateTime.add(base, 3, :second))

      cursor = DateTime.add(base, 10, :second) |> DateTime.to_iso8601()
      viewer_ctx = %{user_can_fix: false, fix_owner_display_name: nil}

      assert {rows, _cursor} =
               ConversationData.load_older(session_uri, owner, cursor, viewer_ctx)

      assert Enum.map(rows, &Map.fetch!(&1, "text")) == ["public-old", "public-new"]
    end
  end
end
