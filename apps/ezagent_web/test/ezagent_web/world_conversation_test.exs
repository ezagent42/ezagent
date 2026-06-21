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

  test "inbound bridge subscribes to the VIEWED session even when it is cold", %{conn: conn} do
    # Regression for the PR-1 E2E bug: subscribing only to the live
    # `list_sessions/1` set missed a viewed session that was not yet a live
    # Kind (cold after a server restart), so the sender never saw their own
    # `:cast` message. The conversation route must subscribe to the in-view
    # session regardless of liveness. This session URI is never spawned, so it
    # is absent from the live registry — yet a broadcast on its topic must
    # still reach the island.
    cold_uri = Ezagent.URI.new!("session://system/default/coldsub-#{System.unique_integer([:positive])}")
    encoded = cold_uri |> URI.to_string() |> URI.encode_www_form()

    {:ok, view, _html} = live(admin_conn(conn), "/sessions?session=#{encoded}")

    msg = Ezagent.Message.new(Ezagent.Entity.User.admin_uri(), %{text: "cold-session-inbound"})

    Phoenix.PubSub.broadcast(
      EzagentCore.PubSub,
      SessionBehavior.session_events_topic(cold_uri),
      {:chat_message, cold_uri, msg}
    )

    assert_push_event(view, "chat:message", %{"message" => pushed})
    assert pushed["text"] == "cold-session-inbound"
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

  test "PR-2a: a joined member appears in member_options and @name lands as a recipient",
       %{conn: conn} do
    member = "entity://system/user/world_mention_#{System.unique_integer([:positive])}"
    member_uri = Ezagent.URI.new!(member)
    segment = Ezagent.URI.name!(member_uri)
    session_uri = world_session_uri()
    encoded = session_uri |> URI.to_string() |> URI.encode_www_form()

    :ok =
      create_read_only_user(member_uri, [
        session_cap(member_uri, session_uri, :join),
        session_cap(member_uri, session_uri, :send)
      ])

    # Join so the member lands in the session slice members map.
    :ok =
      Ezagent.Invocation.dispatch(%Ezagent.Invocation{
        target: Ezagent.URI.with_action(session_uri, :session, :join),
        mode: :call,
        args: %{member: member_uri},
        ctx: %{caller: member_uri, caps: MapSet.new([session_cap(member_uri, session_uri, :join)]), reply: :ignore}
      })
      |> case do
        :ok -> :ok
        {:ok, _} -> :ok
      end

    conn =
      conn
      |> Map.put(:host, "world.ezagent.chat")
      |> Plug.Test.init_test_session(%{
        "current_entity_uri" => member,
        "current_workspace_uri" => "workspace://system"
      })

    {:ok, view, _html} = live(conn, "/sessions?session=#{encoded}")

    # member_options (the autocomplete source) includes the joined member.
    state = world_state(view)
    member_uris = for m <- state["members"] || [], do: m["uri"]
    assert member in member_uris

    # @<segment> must land the member in msg.mentions — the recipient resolver
    # consumes this list, so a wrong parse silently routes nowhere.
    Phoenix.PubSub.subscribe(EzagentCore.PubSub, SessionBehavior.session_events_topic(session_uri))

    view
    |> element("#world-root")
    |> render_hook("world:dispatch", %{
      "action" => "chat.send",
      "args" => %{"session_uri" => URI.to_string(session_uri), "text" => "ping @#{segment} please"}
    })

    assert_receive {:chat_message, _src, %Ezagent.Message{} = msg}, 2_000
    assert member in Enum.map(msg.mentions, &URI.to_string/1)
  end

  test "PR-3a: an inbound membership event pushes a members update to the panel",
       %{conn: conn} do
    session_uri = world_session_uri()
    encoded = session_uri |> URI.to_string() |> URI.encode_www_form()

    {:ok, view, _html} = live(admin_conn(conn), "/sessions?session=#{encoded}")

    # A membership/presence event on the in-view session re-reads members and
    # pushes them to the React panel (PR-1 dropped these; PR-3a handles them).
    send(view.pid, {:member_joined, Ezagent.URI.new!("entity://system/agent/codex-x")})

    assert_push_event(view, "members:update", %{"members" => members})
    assert is_list(members)
  end

  test "PR-3a: self-join on view makes the viewer present and surfaces members it didn't bring",
       %{conn: conn} do
    # The gap PR-3a's `is_list(members)` assertion missed: `member_options/1`
    # reads the LIVE slice via self-join. Without self-join-on-view, a viewer who
    # never joined is absent from the members map and the panel shows only whoever
    # else is live. This test pins BOTH halves of the fix:
    #   (a) a member joined by SOMEONE ELSE (alice) surfaces to the viewer, and
    #   (b) the VIEWER (admin) becomes a member by mounting — impossible without
    #       self-join. Both fail on the pre-fix code.
    alice = "entity://system/user/world_cold_#{System.unique_integer([:positive])}"
    alice_uri = Ezagent.URI.new!(alice)
    session_uri = world_session_uri()
    encoded = session_uri |> URI.to_string() |> URI.encode_www_form()

    :ok =
      create_read_only_user(alice_uri, [
        session_cap(alice_uri, session_uri, :join),
        session_cap(alice_uri, session_uri, :send)
      ])

    # alice joins (she is NOT the viewer) → present in the session members.
    :ok =
      Ezagent.Invocation.dispatch(%Ezagent.Invocation{
        target: Ezagent.URI.with_action(session_uri, :session, :join),
        mode: :call,
        args: %{member: alice_uri},
        ctx: %{
          caller: alice_uri,
          caps: MapSet.new([session_cap(alice_uri, session_uri, :join)]),
          reply: :ignore
        }
      })
      |> case do
        :ok -> :ok
        {:ok, _} -> :ok
      end

    # admin (a DIFFERENT caller, never joined) opens the conversation → self-join
    # adds admin AND the panel reads the live members incl. alice.
    {:ok, _view, _html} = live(admin_conn(conn), "/sessions?session=#{encoded}")

    assert {:ok, %{members: members}} = Ezagent.Kind.get_slice(session_uri, :session)
    member_uris = Enum.map(Map.keys(members), &URI.to_string/1)

    # (a) a member the viewer didn't bring is visible.
    assert alice in member_uris
    # (b) the viewer is now a member — the self-join half that the pre-fix mount
    # (subscribe-only) never did.
    assert URI.to_string(Ezagent.Entity.User.admin_uri()) in member_uris
  end

  test "PR-2b: :session :attach authorizes a member with the cap, denies others", %{conn: _conn} do
    # The genesis `main` session always exists (`:join`/`:attach` don't CREATE a
    # session — only this default does), so all dispatch probes target it.
    session_uri = world_session_uri()
    member = "entity://system/user/world_attach_#{System.unique_integer([:positive])}"
    member_uri = Ezagent.URI.new!(member)

    :ok =
      create_read_only_user(member_uri, [
        session_cap(member_uri, session_uri, :join),
        session_cap(member_uri, session_uri, :send),
        session_cap(member_uri, session_uri, :attach)
      ])

    # Join first — `:join` is the session creation path; `:attach` does not spawn
    # a never-created session, so the session must exist before probing :attach.
    :ok =
      Ezagent.Invocation.dispatch(%Ezagent.Invocation{
        target: Ezagent.URI.with_action(session_uri, :session, :join),
        mode: :call,
        args: %{member: member_uri},
        ctx: %{
          caller: member_uri,
          caps: MapSet.new([session_cap(member_uri, session_uri, :join)]),
          reply: :ignore
        }
      })
      |> case do
        :ok -> :ok
        {:ok, _} -> :ok
      end

    attach = fn caller_uri, caps ->
      Ezagent.Invocation.dispatch(%Ezagent.Invocation{
        target: Ezagent.URI.with_action(session_uri, :session, :attach),
        mode: :call,
        args: %{filename: "x.txt"},
        ctx: %{caller: caller_uri, caps: caps, reply: :ignore}
      })
    end

    # Member holding the :attach cap → authorized (the thin gate acks).
    assert match?(
             {:ok, _},
             attach.(member_uri, MapSet.new([session_cap(member_uri, session_uri, :attach)]))
           )

    # EMPTY ctx caps still authorize via the member's STORED :attach cap (the
    # runtime's live-slice/granted-via path). This is what lets the upload
    # controller dispatch WITHOUT assembling caps itself (`Identity.list_caps_for`
    # is a p13 anti-pattern) — it passes empty caps and the chokepoint derives
    # authority from the caller's identity.
    assert match?({:ok, _}, attach.(member_uri, MapSet.new()))

    # A DIFFERENT member who holds :join + :send but NOT :attach (anywhere — not
    # in ctx, not in stored caps, since the runtime consults the live slice) is
    # DENIED :attach. Proves `:send` is NOT an alias for `:attach` (codex #1):
    # upload needs its own cap, which the participation tier co-grants.
    no_attach = "entity://system/user/world_noattach_#{System.unique_integer([:positive])}"
    no_attach_uri = Ezagent.URI.new!(no_attach)

    :ok =
      create_read_only_user(no_attach_uri, [
        session_cap(no_attach_uri, session_uri, :join),
        session_cap(no_attach_uri, session_uri, :send)
      ])

    :ok =
      Ezagent.Invocation.dispatch(%Ezagent.Invocation{
        target: Ezagent.URI.with_action(session_uri, :session, :join),
        mode: :call,
        args: %{member: no_attach_uri},
        ctx: %{
          caller: no_attach_uri,
          caps: MapSet.new([session_cap(no_attach_uri, session_uri, :join)]),
          reply: :ignore
        }
      })
      |> case do
        :ok -> :ok
        {:ok, _} -> :ok
      end

    assert {:error, :unauthorized} =
             attach.(no_attach_uri, MapSet.new([session_cap(no_attach_uri, session_uri, :send)]))
  end

  test "PR-2b: a valid upload grant embeds its URI; a forged/cross-session grant is dropped",
       %{conn: conn} do
    caller = "entity://system/user/world_grant_#{System.unique_integer([:positive])}"
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

    upload_uri = "resource://system/uploads/#{Ecto.UUID.generate()}-report.pdf"

    valid_grant =
      Phoenix.Token.sign(EzagentWeb.Endpoint, "world_attach", %{
        "uri" => upload_uri,
        "caller" => caller,
        "session" => URI.to_string(session_uri)
      })

    # A grant bound to a DIFFERENT session must NOT attach (laundering attempt).
    foreign_grant =
      Phoenix.Token.sign(EzagentWeb.Endpoint, "world_attach", %{
        "uri" => "resource://system/uploads/#{Ecto.UUID.generate()}-evil.pdf",
        "caller" => caller,
        "session" => "session://system/default/other"
      })

    Phoenix.PubSub.subscribe(EzagentCore.PubSub, SessionBehavior.session_events_topic(session_uri))

    view
    |> element("#world-root")
    |> render_hook("world:dispatch", %{
      "action" => "chat.send",
      "args" => %{
        "session_uri" => URI.to_string(session_uri),
        "text" => "see attached",
        "grants" => [valid_grant, foreign_grant, "not-a-token"]
      }
    })

    assert_receive {:chat_message, _src, %Ezagent.Message{} = msg}, 2_000
    attachments = msg.body |> Map.get(:attachments, Map.get(msg.body, "attachments", [])) |> Enum.map(&to_string/1)

    assert upload_uri in attachments
    refute Enum.any?(attachments, &(&1 =~ "evil.pdf"))
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

  test "ConversationData.build_message embeds parsed mentions + verified attachments", %{conn: _conn} do
    sender = Ezagent.URI.new!("entity://system/user/admin")
    session = Ezagent.URI.new!("session://system/default/none-#{System.unique_integer([:positive])}")

    # mentions: cold session → empty members → only an explicit @entity:// URI survives.
    msg = Ezagent.World.ConversationData.build_message(sender, "ping @entity://system/agent/codex-1", session)
    assert Enum.map(msg.mentions, &URI.to_string/1) == ["entity://system/agent/codex-1"]

    # PR-2b: build_message/4 embeds the (already-verified) attachment URIs.
    att = Ezagent.URI.new!("resource://system/uploads/#{Ecto.UUID.generate()}-doc.pdf")
    msg2 = Ezagent.World.ConversationData.build_message(sender, "see doc", session, [att])
    embedded = msg2.body |> Map.get(:attachments, Map.get(msg2.body, "attachments", []))
    assert Enum.map(embedded, &to_string/1) == [URI.to_string(att)]
  end

  test "ConversationData.message_row mints a download link for uploads, plain label otherwise (PR-2b)",
       %{conn: _conn} do
    att = Ezagent.URI.new!("resource://system/uploads/#{Ecto.UUID.generate()}-report.pdf")

    upload_msg =
      Ezagent.Message.new(Ezagent.Entity.User.admin_uri(), %{text: "x", attachments: [att]})

    [attachment] = Ezagent.World.ConversationData.message_row(upload_msg)["attachments"]
    assert attachment["name"] == "report.pdf"
    assert attachment["href"] =~ "/uploads/download?token="

    plain_msg =
      Ezagent.Message.new(Ezagent.Entity.User.admin_uri(), %{text: "x", attachments: ["just-a-string"]})

    assert [%{"name" => "just-a-string", "href" => nil}] =
             Ezagent.World.ConversationData.message_row(plain_msg)["attachments"]
  end

  # --- helpers ----------------------------------------------------------

  defp world_state(view) do
    html = render(view)

    [_, json] = Regex.run(~r/data-world-state="([^"]*)"/, html)

    json
    |> html_unescape()
    |> Jason.decode!()
  end

  defp html_unescape(s) do
    s
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
  end

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
