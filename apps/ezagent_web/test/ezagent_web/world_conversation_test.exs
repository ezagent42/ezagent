defmodule EzagentWeb.WorldConversationTest do
  @moduledoc """
  PR-1 (LV→world parity migration) — session conversation core.

  Covers the conversation read-path, the composer `:session :send` dispatch,
  the `?session=` deep-link switch, and — the highest-risk piece (codex C1) —
  the INBOUND realtime bridge: a `{:chat_message, session_uri, %Message{}}`
  broadcast on the session events topic reaches the React island via
  `push_event`, and a foreign-session event is dropped by the source guard.
  PubSub→push_event timing is exactly what flakes in a browser test, so it is
  pinned here in a LiveViewTest rather than only in the agent-browser E2E.
  """
  use EzagentWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Ezagent.Behavior.Session, as: SessionBehavior

  setup do
    prior_home = System.get_env("EZAGENT_HOME")

    home =
      Path.join(System.tmp_dir!(), "ezagent_world_conv_#{System.unique_integer([:positive])}")

    System.put_env("EZAGENT_HOME", home)

    on_exit(fn ->
      if prior_home,
        do: System.put_env("EZAGENT_HOME", prior_home),
        else: System.delete_env("EZAGENT_HOME")

      File.rm_rf!(home)
    end)

    :ok
  end

  test "conversation deep-link mounts the conversation component", %{conn: conn} do
    session_uri = world_session_uri()
    encoded = session_uri |> URI.to_string() |> URI.encode_www_form()

    {:ok, view, html} = live(admin_conn(conn), "/sessions?session=#{encoded}")

    assert html =~ ~s(id="world-root")
    assert has_element?(view, "#world-root[data-world-component='conversation']")
    assert html =~ ~s(&quot;component&quot;:&quot;conversation&quot;)
    # The in-view session is wired into the data attribute the inbound filter
    # and composer read from.
    assert has_element?(
             view,
             "#world-root[data-current-session-uri='#{URI.to_string(session_uri)}']"
           )
  end

  test "bare /sessions stays the launcher table (no session param)", %{conn: conn} do
    {:ok, view, _html} = live(admin_conn(conn), "/sessions")
    assert has_element?(view, "#world-root[data-world-component='sessions_table']")
  end

  test "inbound chat broadcast on the session topic reaches the island", %{conn: conn} do
    session_uri = world_session_uri()
    encoded = session_uri |> URI.to_string() |> URI.encode_www_form()

    {:ok, view, _html} = live(admin_conn(conn), "/sessions?session=#{encoded}")

    msg = Ezagent.Message.new(Ezagent.Entity.User.admin_uri(), %{text: "inbound-via-pubsub"})

    Phoenix.PubSub.broadcast(
      EzagentCore.PubSub,
      SessionBehavior.session_events_topic(session_uri),
      {:chat_message, session_uri, msg}
    )

    assert_push_event(view, "chat:message", %{"message" => pushed})
    assert pushed["text"] == "inbound-via-pubsub"
    assert pushed["id"] == msg.id
  end

  test "inbound chat for a FOREIGN session is dropped by the source guard", %{conn: conn} do
    session_uri = world_session_uri()
    encoded = session_uri |> URI.to_string() |> URI.encode_www_form()

    {:ok, view, _html} = live(admin_conn(conn), "/sessions?session=#{encoded}")

    foreign_uri = Ezagent.URI.new!("session://system/default/other-#{System.unique_integer([:positive])}")
    foreign_msg = Ezagent.Message.new(Ezagent.Entity.User.admin_uri(), %{text: "foreign-should-drop"})

    # Direct send simulates an inbound from another subscribed workspace
    # session, isolating the source guard from PubSub timing.
    send(view.pid, {:chat_message, foreign_uri, foreign_msg})

    refute_push_event(view, "chat:message", %{}, 100)
  end

  test "composer chat.send dispatches :session :send for a capped caller", %{conn: conn} do
    caller = "entity://system/user/world_send_#{System.unique_integer([:positive])}"
    caller_uri = Ezagent.URI.new!(caller)
    session_uri = world_session_uri()
    encoded = session_uri |> URI.to_string() |> URI.encode_www_form()

    :ok =
      create_read_only_user(caller_uri, [
        session_cap(caller_uri, session_uri, :join),
        session_cap(caller_uri, session_uri, :send)
      ])

    conn =
      conn
      |> Map.put(:host, "world.ezagent.chat")
      |> Plug.Test.init_test_session(%{
        "current_entity_uri" => caller,
        "current_workspace_uri" => "workspace://system"
      })

    {:ok, view, _html} = live(conn, "/sessions?session=#{encoded}")

    html =
      view
      |> element("#world-root")
      |> render_hook("world:dispatch", %{
        "action" => "chat.send",
        "args" => %{"session_uri" => URI.to_string(session_uri), "text" => "hello world"}
      })

    assert html =~ ~s(data-last-dispatch="ok")

    # The cast'd message comes back via the inbound bridge (sender sees its
    # OWN message only through the broadcast).
    assert_push_event(view, "chat:message", %{"message" => pushed})
    assert pushed["text"] == "hello world"
    assert pushed["sender"] == caller
  end

  test "empty composer text is refused without dispatch", %{conn: conn} do
    session_uri = world_session_uri()
    encoded = session_uri |> URI.to_string() |> URI.encode_www_form()

    {:ok, view, _html} = live(admin_conn(conn), "/sessions?session=#{encoded}")

    html =
      view
      |> element("#world-root")
      |> render_hook("world:dispatch", %{
        "action" => "chat.send",
        "args" => %{"session_uri" => URI.to_string(session_uri), "text" => "   "}
      })

    assert html =~ ~s(data-last-dispatch="error:empty_message")
  end

  test "session.switch push_patches to the ?session= deep-link", %{conn: conn} do
    session_uri = world_session_uri()
    encoded = session_uri |> URI.to_string() |> URI.encode_www_form()

    {:ok, view, _html} = live(admin_conn(conn), "/sessions")

    view
    |> element("#world-root")
    |> render_hook("world:dispatch", %{
      "action" => "session.switch",
      "args" => %{"session_uri" => URI.to_string(session_uri)}
    })

    assert_patch(view, "/sessions?session=#{encoded}")
    assert has_element?(view, "#world-root[data-world-component='conversation']")
  end

  # --- helpers ----------------------------------------------------------

  defp admin_conn(conn) do
    conn
    |> Map.put(:host, "world.ezagent.chat")
    |> Plug.Test.init_test_session(%{
      "current_entity_uri" => URI.to_string(Ezagent.Entity.User.admin_uri()),
      "current_workspace_uri" => "workspace://system"
    })
  end

  defp create_read_only_user(uri, caps) do
    result =
      case Ezagent.Users.create_read_only(uri, caps) do
        {:ok, _} -> :ok
        {:error, %Ecto.Changeset{errors: [uri: {"has already been taken", _}]}} -> :ok
      end

    with :ok <- result do
      Ezagent.Entity.spawn_principal(uri)
    end
  end

  defp world_session_uri do
    Ezagent.URI.workspace(:system)
    |> EzagentDomainInstanceMessage.list_sessions()
    |> List.first()
    |> case do
      %URI{} = uri -> uri
      _ -> Ezagent.URI.new!("session://system/default/main")
    end
  end

  defp session_cap(caller_uri, session_uri, action) do
    %Ezagent.Capability{
      kind: :session,
      behavior: Ezagent.Behavior.Session,
      action: action,
      instance: session_uri,
      workspace_uri: Ezagent.URI.workspace(:system),
      granted_by: caller_uri,
      granted_at: DateTime.utc_now()
    }
  end
end
