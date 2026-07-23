defmodule Ezagent.Socialware.ReadUnfilteredNotAGateTest do
  @moduledoc "S-1: read_unfiltered modifies rows only after tier-1 authorizes the reader."

  use EzagentCore.DataCase, async: false

  alias Ezagent.{Capability, KindRegistry, Message, MessageStore}
  alias Ezagent.Entity.{Session, User}
  alias Ezagent.Socialware.SessionReads
  alias Ezagent.Test.CapHelper

  test "a non-member holding only read_unfiltered is denied at the read chokepoint" do
    session = spawn_session()
    reader = user("non-member")
    unfiltered = CapHelper.signed_cap!(session, reader, read_unfiltered_cap(session))
    spawn_user(reader, [unfiltered])

    refute SessionReads.authorized?(reader, session)

    assert {:error, :unauthorized} =
             SessionReads.messages(reader, session, :conversation, %{limit: 50})
  end

  test "read_unfiltered widens rows only for an already-authorized member" do
    session = spawn_session()
    reader = user("member")

    member = CapHelper.signed_cap!(session, reader, member_cap(session))
    unfiltered = CapHelper.signed_cap!(session, reader, read_unfiltered_cap(session))
    spawn_user(reader, [member, unfiltered])

    write(session, "public", :external_visible)
    write(session, "internal", :internal)

    assert SessionReads.authorized?(reader, session)
    assert {:ok, messages} = SessionReads.messages(reader, session, :conversation, %{limit: 50})

    assert Enum.sort(Enum.map(messages, &text/1)) == ["internal", "public"]
  end

  defp spawn_session do
    session =
      Ezagent.URI.session(
        :team_alpha,
        :default,
        "s1-unfiltered-#{System.unique_integer([:positive])}"
      )

    owner = Ezagent.Entity.User.admin_uri()

    {:ok, _pid} =
      Ezagent.Socialware.TestCapHelper.spawn_session(%{
        uri: session,
        owner_uri: owner,
        behaviors: Session.behaviors()
      })

    :ok = Ezagent.WorkspaceRegistry.bind(session, Capability.workspace_of(session))
    on_exit(fn -> terminate(session, EzagentDomainInstanceMessage.SessionSupervisor) end)
    session
  end

  defp spawn_user(uri, caps) do
    {:ok, _pid} = Ezagent.Kind.spawn(User, %{uri: uri, initial_caps: MapSet.new(caps)})
    on_exit(fn -> terminate(uri, EzagentDomainIdentity.Application.UserSupervisor) end)
  end

  defp terminate(uri, supervisor) do
    case KindRegistry.lookup(uri) do
      {:ok, pid} -> DynamicSupervisor.terminate_child(supervisor, pid)
      :error -> :ok
    end
  rescue
    _ -> :ok
  end

  defp write(session, body, visibility) do
    message =
      Message.new(user("sender"), %{text: body, attachments: []}, visibility: visibility)

    assert {:ok, _stored} = MessageStore.write(message, session)
  end

  defp text(%{body: %{"text" => text}}), do: text
  defp text(%{body: %{text: text}}), do: text

  defp member_cap(session), do: cap(:receive, session)
  defp read_unfiltered_cap(session), do: cap(:read_unfiltered, session)

  defp cap(action, session) do
    Capability.cap(
      :session,
      Ezagent.ActionSet.Session,
      action,
      session,
      Capability.workspace_of(session)
    )
  end

  defp user(prefix),
    do: Ezagent.URI.user(:team_alpha, "#{prefix}-#{System.unique_integer([:positive])}")
end
