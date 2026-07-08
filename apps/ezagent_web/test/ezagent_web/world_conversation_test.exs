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

  alias Ezagent.Agent.RecipeRegistry
  alias Ezagent.ActionSet.Session, as: SessionBehavior
  alias Ezagent.Routing.Matcher
  alias Ezagent.Routing.RuleStore
  alias Ezagent.Socialware.{AnonBinding, AnonUser, ExternalFeed}
  alias Ezagent.ConfigGovernance.Socialware, as: SocialwareGovernance
  alias EzagentDomainInstanceMessage.Routing.MentionRouting

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

    assert_push_event(view, "chat:message", %{"message" => pushed}, 1_000)
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
    cold_uri =
      Ezagent.URI.new!("session://system/default/coldsub-#{System.unique_integer([:positive])}")

    encoded = cold_uri |> URI.to_string() |> URI.encode_www_form()

    {:ok, view, _html} = live(admin_conn(conn), "/sessions?session=#{encoded}")

    msg = Ezagent.Message.new(Ezagent.Entity.User.admin_uri(), %{text: "cold-session-inbound"})

    Phoenix.PubSub.broadcast(
      EzagentCore.PubSub,
      SessionBehavior.session_events_topic(cold_uri),
      {:chat_message, cold_uri, msg}
    )

    assert_push_event(view, "chat:message", %{"message" => pushed}, 1_000)
    assert pushed["text"] == "cold-session-inbound"
  end

  test "inbound chat for a FOREIGN session is dropped by the source guard", %{conn: conn} do
    session_uri = world_session_uri()
    encoded = session_uri |> URI.to_string() |> URI.encode_www_form()

    {:ok, view, _html} = live(admin_conn(conn), "/sessions?session=#{encoded}")

    foreign_uri =
      Ezagent.URI.new!("session://system/default/other-#{System.unique_integer([:positive])}")

    foreign_msg =
      Ezagent.Message.new(Ezagent.Entity.User.admin_uri(), %{text: "foreign-should-drop"})

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
    assert_push_event(view, "chat:message", %{"message" => pushed}, 1_000)
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
    Phoenix.PubSub.subscribe(
      EzagentCore.PubSub,
      SessionBehavior.session_events_topic(session_uri)
    )

    view
    |> element("#world-root")
    |> render_hook("world:dispatch", %{
      "action" => "chat.send",
      "args" => %{
        "session_uri" => URI.to_string(session_uri),
        "text" => "ping @#{segment} please"
      }
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

    Phoenix.PubSub.subscribe(
      EzagentCore.PubSub,
      SessionBehavior.session_events_topic(session_uri)
    )

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

    attachments =
      msg.body
      |> Map.get(:attachments, Map.get(msg.body, "attachments", []))
      |> Enum.map(&to_string/1)

    assert upload_uri in attachments
    refute Enum.any?(attachments, &(&1 =~ "evil.pdf"))
  end

  test "PR-3b: session.invite adds the invited entity to the session", %{conn: conn} do
    session_uri = world_session_uri()
    encoded = session_uri |> URI.to_string() |> URI.encode_www_form()

    invitee = "entity://system/user/world_invitee_#{System.unique_integer([:positive])}"
    invitee_uri = Ezagent.URI.new!(invitee)
    # The invited member must be a registered/live Kind (:join requires it).
    :ok = create_read_only_user(invitee_uri, [])

    # admin opens the conversation → self-join provisions admin's owner-rooted
    # :join authority (so the invite below authorizes via the live slice).
    {:ok, view, _html} = live(admin_conn(conn), "/sessions?session=#{encoded}")

    html =
      view
      |> element("#world-root")
      |> render_hook("world:dispatch", %{
        "action" => "session.invite",
        "args" => %{"session_uri" => URI.to_string(session_uri), "member" => invitee}
      })

    assert html =~ ~s(data-last-dispatch="ok")

    assert {:ok, %{members: members}} = Ezagent.Kind.get_slice(session_uri, :session)
    assert invitee in Enum.map(Map.keys(members), &URI.to_string/1)
  end

  test "PR-3b: session.invite with a malformed member URI yields an error status", %{conn: conn} do
    session_uri = world_session_uri()
    encoded = session_uri |> URI.to_string() |> URI.encode_www_form()

    {:ok, view, _html} = live(admin_conn(conn), "/sessions?session=#{encoded}")

    html =
      view
      |> element("#world-root")
      |> render_hook("world:dispatch", %{
        "action" => "session.invite",
        "args" => %{"session_uri" => URI.to_string(session_uri), "member" => "not a uri"}
      })

    assert html =~ ~s(data-last-dispatch="error:bad_member_uri")
  end

  test "session.remove_participant removes an invited entity from the session", %{conn: conn} do
    session_uri = world_session_uri()
    encoded = session_uri |> URI.to_string() |> URI.encode_www_form()

    invitee = "entity://system/user/world_remove_#{System.unique_integer([:positive])}"
    invitee_uri = Ezagent.URI.new!(invitee)
    :ok = create_read_only_user(invitee_uri, [])

    {:ok, view, _html} = live(admin_conn(conn), "/sessions?session=#{encoded}")

    view
    |> element("#world-root")
    |> render_hook("world:dispatch", %{
      "action" => "session.invite",
      "args" => %{"session_uri" => URI.to_string(session_uri), "member" => invitee}
    })

    assert {:ok, %{members: members}} = Ezagent.Kind.get_slice(session_uri, :session)
    assert invitee in Enum.map(Map.keys(members), &URI.to_string/1)

    html =
      view
      |> element("#world-root")
      |> render_hook("world:dispatch", %{
        "action" => "session.remove_participant",
        "args" => %{"session_uri" => URI.to_string(session_uri), "participant" => invitee}
      })

    assert html =~ ~s(data-last-dispatch="ok")
    assert {:ok, %{members: members}} = Ezagent.Kind.get_slice(session_uri, :session)
    refute invitee in Enum.map(Map.keys(members), &URI.to_string/1)
  end

  test "session.remove_participant refuses to remove the current viewer from members", %{
    conn: conn
  } do
    session_uri = world_session_uri()
    encoded = session_uri |> URI.to_string() |> URI.encode_www_form()
    caller_uri = Ezagent.Entity.User.admin_uri()

    # Opening the conversation self-joins the current viewer; the members panel
    # must not offer or accept the same remove action for that viewer.
    {:ok, view, _html} = live(admin_conn(conn), "/sessions?session=#{encoded}")

    html =
      view
      |> element("#world-root")
      |> render_hook("world:dispatch", %{
        "action" => "session.remove_participant",
        "args" => %{
          "session_uri" => URI.to_string(session_uri),
          "participant" => URI.to_string(caller_uri)
        }
      })

    assert html =~ ~s(data-last-dispatch="error:self_remove_not_allowed")
    assert {:ok, %{members: members}} = Ezagent.Kind.get_slice(session_uri, :session)
    assert URI.to_string(caller_uri) in Enum.map(Map.keys(members), &URI.to_string/1)
  end

  test "PR-4: session.create persists a new session and opens its conversation", %{conn: conn} do
    short_name = "world-pr4-#{System.unique_integer([:positive])}"

    {:ok, view, _html} = live(admin_conn(conn), "/sessions")

    view
    |> element("#world-root")
    |> render_hook("world:dispatch", %{
      "action" => "session.create",
      "args" => %{
        "short_name" => short_name,
        "template_name" => "default"
      }
    })

    new_uri = Ezagent.URI.new!("session://system/default/#{short_name}")
    encoded = new_uri |> URI.to_string() |> URI.encode_www_form()

    assert_patch(view, "/sessions?session=#{encoded}")

    assert_push_event(view, "world:state", %{
      "component" => "conversation",
      "create_error" => nil,
      "current_session_uri" => pushed_uri
    })

    assert pushed_uri == URI.to_string(new_uri)
    assert new_uri in EzagentDomainInstanceMessage.list_sessions(Ezagent.URI.workspace(:system))
  end

  test "PR-5: sessions state lists installable socialware definitions", %{conn: conn} do
    :ok = Ezagent.Socialware.DefinitionRegistry.seed_builtin_definitions()

    {:ok, _view, html} = live(admin_conn(conn), "/sessions")

    assert html =~ ~s(&quot;socialwares&quot;)
    assert html =~ ~s(&quot;name&quot;:&quot;socialware&quot;)
  end

  test "PR-5: session.create with socialware_ref creates an install template and opens it", %{
    conn: conn
  } do
    :ok = Ezagent.Socialware.DefinitionRegistry.seed_builtin_definitions()
    short_name = "world-pr5-#{System.unique_integer([:positive])}"

    {:ok, view, _html} = live(admin_conn(conn), "/sessions")

    view
    |> element("#world-root")
    |> render_hook("world:dispatch", %{
      "action" => "session.create",
      "args" => %{
        "short_name" => short_name,
        "template_name" => "default",
        "socialware_ref" => "socialware"
      }
    })

    template_name = "socialware-install-socialware"
    new_uri = Ezagent.URI.new!("session://system/#{template_name}/#{short_name}")
    encoded = new_uri |> URI.to_string() |> URI.encode_www_form()

    assert_patch(view, "/sessions?session=#{encoded}")

    assert %URI{} = template_uri = find_session_template_uri!(template_name, "system")
    assert {:ok, content} = Ezagent.Entity.Session.read_template_content(template_uri)
    assert Map.get(content, :installs) == ["socialware"]
    assert Ezagent.Socialware.Installation.installed?(new_uri, "socialware")
  end

  test "session.socialware.uninstall clears install records and session-scoped rules", %{
    conn: conn
  } do
    :ok = Ezagent.Socialware.DefinitionRegistry.seed_builtin_definitions()
    short_name = "world-uninstall-#{System.unique_integer([:positive])}"

    {:ok, view, _html} = live(admin_conn(conn), "/sessions")

    render_hook(element(view, "#world-root"), "world:dispatch", %{
      "action" => "session.create",
      "args" => %{
        "short_name" => short_name,
        "template_name" => "default",
        "socialware_ref" => "socialware"
      }
    })

    template_name = "socialware-install-socialware"
    new_uri = Ezagent.URI.new!("session://system/#{template_name}/#{short_name}")
    encoded = URI.encode_www_form(URI.to_string(new_uri))

    assert_patch(view, "/sessions?session=#{encoded}")
    assert_push_event(view, "world:state", %{"component" => "conversation"})

    {:ok, %{id: _rule_id}} =
      RuleStore.add(
        MentionRouting,
        Matcher.always(),
        [URI.to_string(Ezagent.Entity.User.admin_uri())],
        new_uri
      )

    assert Ezagent.Socialware.Installation.installed?(new_uri, "socialware")

    assert Enum.any?(RuleStore.list(MentionRouting), fn row ->
             row.created_by == URI.to_string(new_uri)
           end)

    html =
      render_hook(element(view, "#world-root"), "world:dispatch", %{
        "action" => "session.socialware.uninstall",
        "args" => %{"session_uri" => URI.to_string(new_uri), "ref" => "socialware"}
      })

    assert html =~ ~s(data-last-dispatch="ok")

    assert_push_event(view, "world:state", %{
      "installed_socialwares" => [],
      "routing_rules" => []
    })

    refute Ezagent.Socialware.Installation.installed?(new_uri, "socialware")

    refute Enum.any?(RuleStore.list(MentionRouting), fn row ->
             row.created_by == URI.to_string(new_uri)
           end)
  end

  test "O-1: session.create with socialware_config_id pins the EXACT revision (content-hash-addressed install)",
       %{conn: conn} do
    # Proves the dispatch-glue (`socialware_config_id`/`socialware_content_hash`
    # args → `socialware_revision/1` → `create_session/5` → `prepare_create_template/5`)
    # threads the revision identity through to a BAKED pin — a silent-nil failure
    # here would quietly revert to the name-keyed O-1 bug with no other test red.
    system_ws = Ezagent.URI.workspace(:system)
    ref = "cidglue-#{System.unique_integer([:positive])}"

    {:ok, definition} =
      Ezagent.Socialware.Definition.new(%{
        name: ref,
        title: "CID glue #{ref}",
        bases: [Ezagent.ActionSet.Session],
        shape: [],
        visibility_policy: %{scope: :public, publish_policy: :auto, web_anon_access: false}
      })

    {:ok, object} =
      Ezagent.Socialware.DefinitionRegistry.write_definition(definition,
        workspace_uri: system_ws,
        caller_workspace_uri: system_ws,
        actor_uri: Ezagent.Entity.User.admin_uri()
      )

    short_name = "world-cid-#{System.unique_integer([:positive])}"
    {:ok, view, _html} = live(admin_conn(conn), "/sessions")

    view
    |> element("#world-root")
    |> render_hook("world:dispatch", %{
      "action" => "session.create",
      "args" => %{
        "short_name" => short_name,
        "template_name" => "default",
        "socialware_ref" => ref,
        "socialware_config_id" => object.id,
        "socialware_content_hash" => object.content_hash
      }
    })

    template_name = "socialware-install-#{ref}"
    new_uri = Ezagent.URI.new!("session://system/#{template_name}/#{short_name}")
    encoded = new_uri |> URI.to_string() |> URI.encode_www_form()

    assert_patch(view, "/sessions?session=#{encoded}")

    assert %URI{} = template_uri = find_session_template_uri!(template_name, "system")
    assert {:ok, content} = Ezagent.Entity.Session.read_template_content(template_uri)

    assert {:ok, [install]} =
             Ezagent.Socialware.Installation.parsed_installs_from_template(content)

    assert install.ref == ref
    # The install template is PINNED to the exact revision the dispatch carried.
    assert install.config_id == object.id
    assert install.content_hash == object.content_hash
  end

  # Stage 1/2 (world-views) INTENDED behavior change: the switch whitelist is
  # no longer a hard-coded tab list — it is the caller-aware registry set
  # (`ConversationData.session_view_ids/2`), the SAME source that produces the
  # visible tabs. So a registry-applicable view ("conversation") switches, and
  # an id outside that set is rejected with `error:bad_view` instead of being
  # blindly activated (the old always-switchable "pty" assertion asserted the
  # retired hard-coded behavior).
  test "PR-4: conversation view switch pushes active view state", %{conn: conn} do
    session_uri = world_session_uri()
    encoded = session_uri |> URI.to_string() |> URI.encode_www_form()

    {:ok, view, _html} = live(admin_conn(conn), "/sessions?session=#{encoded}")

    view
    |> element("#world-root")
    |> render_hook("world:dispatch", %{
      "action" => "session.view.switch",
      "args" => %{"session_uri" => URI.to_string(session_uri), "view" => "conversation"}
    })

    assert_push_event(view, "world:state", %{"active_view" => "conversation"})

    # An id not in the registry-driven set for this session is rejected —
    # no active_view push, dispatch status surfaces the reject.
    html =
      view
      |> element("#world-root")
      |> render_hook("world:dispatch", %{
        "action" => "session.view.switch",
        "args" => %{
          "session_uri" => URI.to_string(session_uri),
          "view" => "not_a_registered_view"
        }
      })

    assert html =~ ~s(data-last-dispatch="error:bad_view")
    refute_push_event(view, "world:state", %{"active_view" => "not_a_registered_view"}, 100)
  end

  test "PR-4: switching to a member PTY records the active agent", %{conn: conn} do
    session_uri = world_session_uri()
    encoded = session_uri |> URI.to_string() |> URI.encode_www_form()
    agent = "entity://system/agent/world-pr4-pty"

    {:ok, view, _html} = live(admin_conn(conn), "/sessions?session=#{encoded}")

    view
    |> element("#world-root")
    |> render_hook("world:dispatch", %{
      "action" => "session.pty.open",
      "args" => %{"session_uri" => URI.to_string(session_uri), "agent" => agent}
    })

    assert_push_event(view, "world:state", %{
      "active_view" => "pty",
      "active_pty_agent_uri" => ^agent
    })
  end

  test "PR-4: restart_orchestrator denies a caller without the restart cap", %{conn: conn} do
    session_uri = world_session_uri()
    encoded = session_uri |> URI.to_string() |> URI.encode_www_form()
    caller = "entity://system/user/world_no_restart_#{System.unique_integer([:positive])}"
    caller_uri = Ezagent.URI.new!(caller)

    :ok = create_read_only_user(caller_uri, [session_cap(caller_uri, session_uri, :join)])

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
        "action" => "session.orchestrator.restart",
        "args" => %{"session_uri" => URI.to_string(session_uri)}
      })

    assert html =~ ~s(data-last-dispatch="error:unauthorized")
  end

  test "PR-4: session routing add scopes a rule to the current session", %{conn: conn} do
    session_uri = world_session_uri()
    encoded = session_uri |> URI.to_string() |> URI.encode_www_form()
    receiver = URI.to_string(Ezagent.Entity.User.admin_uri())

    {:ok, view, _html} = live(admin_conn(conn), "/sessions?session=#{encoded}")

    html =
      view
      |> element("#world-root")
      |> render_hook("world:dispatch", %{
        "action" => "session.routing.add",
        "args" => %{
          "session_uri" => URI.to_string(session_uri),
          "rule" => %{
            "matcher_type" => "always",
            "receivers" => receiver
          }
        }
      })

    assert html =~ ~s(data-last-dispatch="ok")

    session_str = URI.to_string(session_uri)

    assert Enum.any?(RuleStore.list(MentionRouting), fn row ->
             case Matcher.from_json(row.matcher_data) do
               {:ok, matcher} ->
                 row.receivers == [receiver] and matcher_targets_session?(matcher, session_str)

               _ ->
                 false
             end
           end)
  end

  test "PR-4: session routing toggle disables and enables a scoped rule", %{conn: conn} do
    session_uri = world_session_uri()
    encoded = session_uri |> URI.to_string() |> URI.encode_www_form()

    matcher =
      Matcher.all_of([
        Matcher.in_session(session_uri),
        Matcher.always()
      ])

    {:ok, %{id: rule_id}} =
      RuleStore.add(
        MentionRouting,
        matcher,
        [URI.to_string(Ezagent.Entity.User.admin_uri())],
        Ezagent.Entity.User.admin_uri()
      )

    {:ok, view, _html} = live(admin_conn(conn), "/sessions?session=#{encoded}")

    html =
      view
      |> element("#world-root")
      |> render_hook("world:dispatch", %{
        "action" => "session.routing.toggle",
        "args" => %{
          "session_uri" => URI.to_string(session_uri),
          "id" => Integer.to_string(rule_id),
          "table" => Atom.to_string(MentionRouting),
          "enabled" => "true"
        }
      })

    assert html =~ ~s(data-last-dispatch="ok")
    assert Enum.find(RuleStore.list(MentionRouting), &(&1.id == rule_id)).enabled == false

    view
    |> element("#world-root")
    |> render_hook("world:dispatch", %{
      "action" => "session.routing.toggle",
      "args" => %{
        "session_uri" => URI.to_string(session_uri),
        "id" => Integer.to_string(rule_id),
        "table" => Atom.to_string(MentionRouting),
        "enabled" => "false"
      }
    })

    assert Enum.find(RuleStore.list(MentionRouting), &(&1.id == rule_id)).enabled == true
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

  test "session.switch pushes conversation state without a LiveView route remount", %{conn: conn} do
    session_uri = world_session_uri()

    {:ok, view, _html} = live(admin_conn(conn), "/sessions")

    view
    |> element("#world-root")
    |> render_hook("world:dispatch", %{
      "action" => "session.switch",
      "args" => %{"session_uri" => URI.to_string(session_uri)}
    })

    assert_push_event(view, "world:state", %{
      "component" => "conversation",
      "session_uri" => pushed_uri
    })

    assert pushed_uri == URI.to_string(session_uri)

    assert_push_event(
      view,
      "world:url",
      %{
        "path" => pushed_path
      },
      1_000
    )

    assert pushed_path == "/sessions?session=#{URI.encode_www_form(URI.to_string(session_uri))}"
  end

  test "conversation route state includes the Chat path for primary nav highlighting", %{
    conn: conn
  } do
    session_uri = world_session_uri()
    encoded = session_uri |> URI.to_string() |> URI.encode_www_form()

    {:ok, view, _html} = live(admin_conn(conn), "/sessions?session=#{encoded}")

    assert_push_event(view, "world:state", %{
      "component" => "conversation",
      "session_uri" => pushed_uri,
      "path" => "/sessions",
      "title" => "Chat"
    })

    assert pushed_uri == URI.to_string(session_uri)
  end

  test "ConversationData.build_message embeds parsed mentions + verified attachments", %{
    conn: _conn
  } do
    sender = Ezagent.URI.new!("entity://system/user/admin")

    session =
      Ezagent.URI.new!("session://system/default/none-#{System.unique_integer([:positive])}")

    # mentions: cold session → empty members → only an explicit @entity:// URI survives.
    msg =
      Ezagent.World.ConversationData.build_message(
        sender,
        "ping @entity://system/agent/codex-1",
        session
      )

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
      Ezagent.Message.new(Ezagent.Entity.User.admin_uri(), %{
        text: "x",
        attachments: ["just-a-string"]
      })

    assert [%{"name" => "just-a-string", "href" => nil}] =
             Ezagent.World.ConversationData.message_row(plain_msg)["attachments"]
  end

  test "render-card mechanism: a message body carrying a render tree surfaces it on the wire (producer-free)" do
    # Borrows the json-render card shape from #1023 (Card > Table) but spawns NO
    # producer/agent — it just constructs a message whose body HAS a render tree
    # and asserts the transport carries `render`/`render_css` through to the wire.
    render_tree = %{
      "type" => "Card",
      "props" => %{"title" => "Order summary"},
      "children" => [
        %{
          "type" => "Table",
          "props" => %{
            "columns" => ["Item", "Qty"],
            "rows" => [["Widget", 2], ["Gadget", 5]]
          }
        }
      ]
    }

    msg =
      Ezagent.Message.new(Ezagent.Entity.User.admin_uri(), %{
        text: "here is the data",
        render: render_tree,
        render_css: "table{font-size:12px}"
      })

    row = Ezagent.World.ConversationData.message_row(msg)
    assert row["render"] == render_tree
    assert row["render_css"] == "table{font-size:12px}"

    # A message with NO render body surfaces nil (plain text path) — the default.
    plain = Ezagent.Message.new(Ezagent.Entity.User.admin_uri(), %{text: "plain"})
    plain_row = Ezagent.World.ConversationData.message_row(plain)
    assert plain_row["render"] == nil
    assert plain_row["render_css"] == nil
  end

  test "PR-5: profile.display_name.save updates the current entity profile", %{conn: conn} do
    {:ok, view, _html} = live(admin_conn(conn), "/profile")
    name = "World Admin #{System.unique_integer([:positive])}"

    html =
      view
      |> element("#world-root")
      |> render_hook("world:dispatch", %{
        "action" => "profile.display_name.save",
        "args" => %{"display_name" => name}
      })

    assert html =~ ~s(data-last-dispatch="ok")
    assert Ezagent.EntityPresenter.display("entity://system/user/admin") == name
  end

  test "PR-5: admin.smtp.save persists config and keeps an existing password on blank edit",
       %{conn: conn} do
    :ok =
      Ezagent.AppSettings.put("smtp_config", %{
        "host" => "old.example.test",
        "port" => "587",
        "username" => "old",
        "password" => "secret",
        "from_address" => "old@example.test",
        "tls" => true
      })

    {:ok, view, _html} = live(admin_conn(conn), "/admin/settings")

    html =
      view
      |> element("#world-root")
      |> render_hook("world:dispatch", %{
        "action" => "admin.smtp.save",
        "args" => %{
          "smtp" => %{
            "host" => "smtp.example.test",
            "port" => "2525",
            "username" => "world",
            "password" => "",
            "from_address" => "world@example.test",
            "tls" => "false"
          }
        }
      })

    assert html =~ ~s(data-last-dispatch="ok")

    assert %{
             "host" => "smtp.example.test",
             "port" => "2525",
             "username" => "world",
             "password" => "secret",
             "from_address" => "world@example.test",
             "tls" => false
           } = Ezagent.AppSettings.get("smtp_config")
  end

  test "PR-5: feishu.bind and feishu.unbind manage user bindings from world", %{conn: conn} do
    open_id = "ou_world_#{System.unique_integer([:positive])}"
    user_uri = "entity://system/user/admin"

    {:ok, view, _html} = live(admin_conn(conn), "/plugins/feishu/bindings")

    html =
      view
      |> element("#world-root")
      |> render_hook("world:dispatch", %{
        "action" => "feishu.bind",
        "args" => %{"open_id" => open_id, "user_uri" => user_uri}
      })

    assert html =~ ~s(data-last-dispatch="ok")
    assert Enum.any?(EzagentPluginFeishu.UserBinding.list_all(), &(&1.open_id == open_id))

    html =
      view
      |> element("#world-root")
      |> render_hook("world:dispatch", %{
        "action" => "feishu.unbind",
        "args" => %{"open_id" => open_id}
      })

    assert html =~ ~s(data-last-dispatch="ok")
    refute Enum.any?(EzagentPluginFeishu.UserBinding.list_all(), &(&1.open_id == open_id))
  end

  test "PR-6: cmdk.select resolves a server-side command key and patches", %{conn: conn} do
    {:ok, view, _html} = live(admin_conn(conn), "/profile")

    view
    |> element("#world-root")
    |> render_hook("world:dispatch", %{"action" => "cmdk.open", "args" => %{}})

    assert_push_event(view, "world:state", %{"cmdk" => %{"open" => true, "results" => results}})
    assert Enum.any?(results, &(Map.get(&1, "key") == "nav:/sessions"))

    view
    |> element("#world-root")
    |> render_hook("world:dispatch", %{
      "action" => "cmdk.select",
      "args" => %{"key" => "nav:/sessions"}
    })

    assert_patch(view, "/sessions")
  end

  test "PR-6: workspace.member.remove removes a workspace member through the facade",
       %{conn: conn} do
    member =
      Ezagent.URI.new!("entity://system/user/world-remove-#{System.unique_integer([:positive])}")

    :ok = create_read_only_user(member, [])

    ws = Ezagent.Workspace.Store.get_by_name("system")
    members = Enum.uniq_by([member | ws.members], &URI.to_string/1)
    {:ok, _} = Ezagent.Workspace.Store.update_members("system", members)

    {:ok, view, _html} = live(admin_conn(conn), "/workspaces/system")

    html =
      view
      |> element("#world-root")
      |> render_hook("world:dispatch", %{
        "action" => "workspace.member.remove",
        "args" => %{"member_uri" => URI.to_string(member)}
      })

    assert html =~ ~s(data-last-dispatch="ok")
    ws_after = Ezagent.Workspace.Store.get_by_name("system")
    refute Enum.any?(ws_after.members, &(URI.to_string(&1) == URI.to_string(member)))
  end

  test "PR-6: inbound non-chat envelopes are pushed to the React island", %{conn: conn} do
    session_uri = world_session_uri()
    encoded = session_uri |> URI.to_string() |> URI.encode_www_form()
    user_uri = Ezagent.Entity.User.admin_uri()

    {:ok, view, _html} = live(admin_conn(conn), "/sessions?session=#{encoded}")

    envelopes = [
      {"notification", {:notification, user_uri, %{body: %{text: "notice"}}}},
      {"read_marker_updated",
       {:read_marker_updated, session_uri, user_uri, %{source: :displayed}}},
      {"cc_event", {:cc_event, %{event: "stdout"}}},
      {"cc_connected",
       {:cc_connected, Ezagent.URI.new!("entity://system/agent/cc"), %{tools: []}}},
      {"cc_disconnected", {:cc_disconnected, Ezagent.URI.new!("entity://system/agent/cc")}},
      {"slice_changed", {:slice_changed, %{uri: URI.to_string(user_uri), slice_key: :session}}},
      {"audit_event", {:audit_event, %{target: "world"}}},
      {"authz_event", {:authz_event, :ok, %{target: "world"}, DateTime.utc_now()}}
    ]

    for {type, envelope} <- envelopes do
      send(view.pid, envelope)
      assert_push_event(view, "world:inbound", %{"type" => ^type}, 1_000)
    end
  end

  test "world template save persists installs and created sessions allow web anon access", %{
    conn: conn
  } do
    :ok = Ezagent.Socialware.DefinitionRegistry.seed_builtin_definitions()
    template_name = "world-public-#{System.unique_integer([:positive])}"
    session_name = "world-public-session-#{System.unique_integer([:positive])}"

    {:ok, view, _html} = live(admin_conn(conn), "/workspaces/system")

    view
    |> element("#world-root")
    |> render_hook("world:dispatch", %{
      "action" => "workspace.template.save",
      "args" => %{
        "template" => %{
          "name" => template_name,
          "description" => "Public socialware template",
          "installs" => ["socialware"]
        }
      }
    })

    assert_push_event(view, "world:state", %{"template_notice" => "template_saved"})

    assert %URI{} = template_uri = find_session_template_uri!(template_name, "system")
    assert {:ok, content} = Ezagent.Entity.Session.read_template_content(template_uri)
    assert Map.get(content, :installs) == ["socialware"]

    view
    |> element("#world-root")
    |> render_hook("world:dispatch", %{
      "action" => "session.create",
      "args" => %{"short_name" => session_name, "template_name" => template_name}
    })

    session_uri = Ezagent.URI.new!("session://system/#{template_name}/#{session_name}")
    encoded = session_uri |> URI.to_string() |> URI.encode_www_form()

    assert_patch(view, "/sessions?session=#{encoded}")
    assert Ezagent.Socialware.PublicView.web_anon_access?(session_uri)
  end

  test "P7: world form authors a complete socialware definition and publishes current", %{
    conn: conn
  } do
    template_name = "world-author-#{System.unique_integer([:positive])}"
    socialware_name = "#{template_name}-app"

    {:ok, view, _html} = live(admin_conn(conn), "/workspaces/system")

    view
    |> element("#world-root")
    |> render_hook("world:dispatch", %{
      "action" => "workspace.template.save",
      "args" => %{
        "template" => %{
          "name" => template_name,
          "description" => "Full socialware authoring",
          "socialware" => %{
            "name" => socialware_name,
            "bases" => [
              "Ezagent.ActionSet.Session",
              "Ezagent.ActionSet.Publisher.SessionImpl"
            ],
            "shape" => [
              "Ezagent.ActionSet.Turn",
              "Ezagent.ActionSet.Surface"
            ],
            "roles" => [
              %{"role_name" => "bot", "fill" => "human"}
            ],
            "routing_rules" => [
              %{
                "matcher" => %{"type" => "always"},
                "receivers" => ["bot"],
                "rule_set" => "default",
                "position" => 0,
                "prompt_template_ref" => "answer"
              }
            ],
            "prompt_templates" => %{"answer" => "Use the KB context."},
            "legends" => %{
              "support" => %{
                "member_set" => ["bot"],
                "bound_rule_set" => "default",
                "fold" => false
              }
            },
            "adapters" => [
              %{"adapter_id" => "web_feed", "role" => "customer", "config" => %{}}
            ],
            "visibility_policy" => %{
              "publish_policy" => "supervised",
              "web_anon_access" => true
            },
            "owner_policy" => %{
              "type" => "installer"
            }
          }
        }
      }
    })

    assert_push_event(view, "world:state", %{
      "template_notice" => "template_saved",
      "last_socialware_ref" => ^socialware_name
    })

    assert {:ok, definition, _object} =
             Ezagent.Socialware.DefinitionRegistry.lookup(
               Ezagent.URI.workspace(:system),
               socialware_name
             )

    assert [%{role_name: "bot", fill: :human}] = definition.roles
    assert [%{"adapter_id" => "web_feed"}] = definition.adapters
    assert definition.prompt_templates == %{"answer" => "Use the KB context."}
    assert Map.has_key?(definition.legends, "support")
    assert definition.owner_policy == %{type: :installer}

    assert definition.visibility_policy == %{
             scope: :private,
             publish_policy: :supervised,
             web_anon_access: true
           }

    assert %URI{} = template_uri = find_session_template_uri!(template_name, "system")
    assert {:ok, content} = Ezagent.Entity.Session.read_template_content(template_uri)
    assert Map.get(content, :installs) == [socialware_name]
    refute Map.has_key?(content, :members)
    refute Map.has_key?(content, :routing_rules)

    expected_hash = template_hash(template_uri)

    assert {:ok, ^expected_hash} =
             Ezagent.TemplateTags.resolve(
               Ezagent.URI.workspace(:system),
               template_name,
               "current"
             )
  end

  test "PR-6: pure-config hello manifest publishes, discovers, installs, materializes py agent, and renders",
       %{conn: conn} do
    :ok = ensure_manifest_reference_apps_started()
    n = System.unique_integer([:positive])
    owner_ws_name = "manifest-owner-#{n}"
    installer_ws_name = "manifest-installer-#{n}"
    manifest_name = "hello-manifest-#{n}"
    recipe_name = "hello-manifest-py-#{n}"
    role_name = "py-helper-#{n}"
    short_name = "hello-run-#{n}"

    {:ok, _} = Ezagent.Workspace.create(owner_ws_name, %{})
    {:ok, _} = Ezagent.Workspace.create(installer_ws_name, %{})

    owner_ws = Ezagent.URI.workspace(owner_ws_name)
    installer_ws = Ezagent.URI.workspace(installer_ws_name)
    installer_user = Ezagent.URI.entity(installer_ws_name, :user, "admin")
    admin = Ezagent.Entity.User.admin_uri()
    :ok = create_read_only_user(installer_user, [])
    :ok = Ezagent.Workspace.add_member(installer_ws_name, installer_user)
    :ok = seed_py_recipe(recipe_name)

    raw_manifest =
      hello_manifest_attrs(%{
        name: manifest_name,
        recipe_name: recipe_name,
        role_name: role_name
      })

    assert {:ok, definition} = Ezagent.Socialware.ManifestResolver.resolve(raw_manifest)

    manage_cap = SocialwareGovernance.manage_cap(manifest_name, owner_ws, admin)

    owner_ctx = %{
      caller: admin,
      workspace_uri: owner_ws,
      caps: MapSet.new([manage_cap, Ezagent.Capability.admin_genesis_cap()])
    }

    assert {:ok, %{cr_id: cr_id}} =
             SocialwareGovernance.open_cr(%{name: manifest_name}, owner_ctx)

    assert {:ok, _} = SocialwareGovernance.stage_definition(cr_id, definition, owner_ctx)
    assert {:ok, %{status: "published"}} = SocialwareGovernance.publish_cr(cr_id, owner_ctx)

    assert Enum.any?(Ezagent.Socialware.DefinitionRegistry.list(installer_ws), fn row ->
             row.name == manifest_name and row.public? == true
           end)

    {:ok, view, html} = live(workspace_conn(conn, installer_ws_name, installer_user), "/sessions")
    assert html =~ ~s(&quot;name&quot;:&quot;#{manifest_name}&quot;)

    view
    |> element("#world-root")
    |> render_hook("world:dispatch", %{
      "action" => "session.create",
      "args" => %{
        "short_name" => short_name,
        "template_name" => "default",
        "socialware_ref" => manifest_name
      }
    })

    template_name = "socialware-install-#{manifest_name}"

    session_uri =
      Ezagent.URI.new!("session://#{installer_ws_name}/#{template_name}/#{short_name}")

    assert_patch(view, "/sessions?session=#{URI.encode_www_form(URI.to_string(session_uri))}")

    assert Ezagent.Socialware.Installation.installed?(session_uri, manifest_name)

    members = Ezagent.Orchestrator.Tools.read_members(session_uri)
    planned_agent = SessionBehavior.role_name_to_uri(members, role_name)
    assert %URI{} = planned_agent

    on_exit(fn ->
      _ = Ezagent.Domain.Python.stop(planned_agent)
      _ = Ezagent.Kind.terminate(planned_agent)
      _ = Ezagent.Kind.terminate(session_uri)
    end)

    # Core PR-6 assertion set: the socialware manifest materialized the py agent
    # as a live, MATERIALIZED + joined session member — Kind alive, ReadyGate
    # :ready (Kind readiness is independent of the Python subprocess), durable
    # flavor/role markers, config_dir allocated. These all pass with `uv` ABSENT
    # (e.g. CI): materialization is decoupled from subprocess-liveness (see
    # `Ezagent.Template.PyAgent.instantiate/3` — a subprocess-start failure keeps
    # the Kind materialized in a degraded state, next :receive surfaces
    # :not_alive). The LIVE Python subprocess (`Python.alive?`) is NOT asserted
    # here so the core E2E does not require uv; the identical materialize code
    # path (`provision_and_instantiate` → `PyAgent.instantiate/3` → subprocess) is
    # covered under `@tag :uv` by
    # `apps/ezagent_plugin_py/test/ezagent/template/py_template_test.exs`.
    assert {:ok, _pid} = Ezagent.KindRegistry.lookup(planned_agent)
    assert :ready = Ezagent.ReadyGate.status(planned_agent)
    assert {:ok, "py"} = Ezagent.AgentFlavorAttributes.get(planned_agent)
    # P2 (Gate B): the agent-level attribute records BUILD PROVENANCE (the recipe
    # name), NOT the session role_name — they diverge here. The session role_name
    # lives on the membership edge (asserted below via `members`).
    assert {:ok, ^recipe_name} = Ezagent.AgentRecipeAttributes.fetch(planned_agent)

    assert {:ok, sandbox_slice} = Ezagent.Kind.get_slice(planned_agent, :sandbox)
    sandbox = Ezagent.Kind.normalize_slice_view(sandbox_slice)
    assert is_binary(Map.get(sandbox, :config_dir_path))

    assert %{^planned_agent => %{role_name: ^role_name}} = members

    caps = Ezagent.Identity.list_caps_for(planned_agent)

    assert Enum.any?(caps, fn cap ->
             cap.behavior == Ezagent.ActionSet.Identity and cap.action == :list_caps
           end)

    page_spec = %{
      "type" => "Stack",
      "props" => %{"direction" => "vertical", "title" => "Manifest hello"},
      "children" => [
        %{
          "type" => "Heading",
          "props" => %{"text" => "Pure-config hello", "level" => 1},
          "children" => []
        }
      ]
    }

    assert {:ok, ^page_spec} = EzagentPluginHello.Spec.validate(page_spec)

    assert {:ok, _turn_id} =
             EzagentPluginHello.TurnDriver.drive(session_uri, page_spec, "manifest page")

    anon = mint_and_join_anon(session_uri)
    snapshot = wait_for_page(session_uri, anon)
    assert snapshot.page == page_spec

    assert Enum.any?(Ezagent.UI.SessionViewRegistry.applicable_views(session_uri, anon), fn row ->
             row.id == :hello_page
           end)

    rendered =
      render_component(&EzagentPluginHello.PageView.render/1, session_uri: session_uri)

    assert rendered =~ "hello-page-renderer"
    assert rendered =~ "Pure-config hello"
  end

  test "#162: Demo.Hello.publish/0 boot-publishes hello as PUBLIC, cross-workspace discoverable, materializable, idempotent" do
    :ok = ensure_manifest_reference_apps_started()
    # The demo references the stable `np` py-role recipe; `RoleSeedHook` skips
    # in :test, so seed it explicitly (same as the acceptance test seeds its
    # own recipe) so conformance/materialization resolve it.
    :ok = seed_np_recipe()

    system_ws = Ezagent.URI.workspace(:system)
    n = System.unique_integer([:positive])
    other_ws_name = "hello-discoverer-#{n}"
    {:ok, _} = Ezagent.Workspace.create(other_ws_name, %{})
    other_ws = Ezagent.URI.workspace(other_ws_name)

    # DOGFOOD the real governance flow (open_cr → stage → publish).
    assert {:ok, :published} = Ezagent.Socialware.Demo.Hello.publish()
    assert Ezagent.Socialware.Demo.Hello.published?()

    # PUBLIC + discoverable from a DIFFERENT workspace via the normal listing.
    assert Enum.any?(Ezagent.Socialware.DefinitionRegistry.list(other_ws), fn row ->
             row.name == "hello" and row.public? == true
           end)

    # Materializable: conformance (every declared ref resolves) is green — the
    # same guarantee `mix ezagent.socialware.check` gives, proving install works.
    assert {:ok, definition, _object} =
             Ezagent.Socialware.DefinitionRegistry.lookup(system_ws, "hello")

    assert :ok = Ezagent.Socialware.Conformance.check(definition, system_ws)

    # Idempotent: a second publish opens NO new CR — it returns :exists via the
    # already-public guard, so re-boots never accumulate duplicate CRs.
    assert {:ok, :exists} = Ezagent.Socialware.Demo.Hello.publish()

    # Still exactly one public `hello` entry (no duplicate definition).
    hello_rows =
      Enum.filter(Ezagent.Socialware.DefinitionRegistry.list(other_ws), &(&1.name == "hello"))

    assert length(hello_rows) == 1
  end

  # --- helpers ----------------------------------------------------------

  defp seed_np_recipe do
    recipe = EzagentPluginPy.Application.np_role_recipe()
    RecipeRegistry.invalidate(RecipeRegistry.system_workspace_uri(), recipe.name)

    case RecipeRegistry.seed_role_if_absent(recipe) do
      {:ok, _} -> :ok
      {:error, reason} -> flunk("failed to seed np recipe: #{inspect(reason)}")
    end
  end

  defp ensure_manifest_reference_apps_started do
    with {:ok, _} <- Application.ensure_all_started(:ezagent_plugin_hello),
         {:ok, _} <- Application.ensure_all_started(:ezagent_plugin_py) do
      :ok = Ezagent.UI.SessionViewRegistry.init()
      :ok = Ezagent.UI.SessionViewRegistry.register(EzagentPluginHello.PageView)

      :ok =
        Ezagent.CapabilityRegistry.register(
          Ezagent.Entity.Session,
          :hello_render,
          Ezagent.ActionSet.HelloRender
        )

      :ok
    else
      {:error, reason} -> flunk("failed to start manifest reference app: #{inspect(reason)}")
    end
  end

  defp seed_py_recipe(recipe_name) do
    base = EzagentPluginPy.Application.np_role_recipe()

    recipe =
      base
      |> Map.put(:name, recipe_name)
      |> Map.put(:requested_caps, [%{behavior: Ezagent.ActionSet.Identity, action: :list_caps}])

    RecipeRegistry.invalidate(RecipeRegistry.system_workspace_uri(), recipe_name)

    case RecipeRegistry.seed_role_if_absent(recipe) do
      {:ok, _} -> :ok
      {:error, reason} -> flunk("failed to seed py recipe: #{inspect(reason)}")
    end
  end

  # One source of truth (task #162): the hello manifest shape now lives in
  # `Ezagent.Socialware.Demo.Hello.manifest_attrs/1` (the lib demo constant the
  # boot-publish path also uses). This test passes UNIQUE per-run names for
  # parallel-test isolation; the boot path uses the stable demo defaults.
  defp hello_manifest_attrs(%{name: name, recipe_name: recipe_name, role_name: role_name}) do
    Ezagent.Socialware.Demo.Hello.manifest_attrs(
      name: name,
      recipe_name: recipe_name,
      role_name: role_name
    )
  end

  defp mint_and_join_anon(session_uri) do
    {:ok, anon_uri} = AnonUser.mint_for_public_session(session_uri)
    :ok = Ezagent.Entity.spawn_principal(anon_uri)
    {:ok, _row} = AnonBinding.touch(anon_uri, session_uri, DateTime.utc_now())

    :ok =
      Ezagent.Invocation.dispatch(%Ezagent.Invocation{
        target: Ezagent.URI.with_action(session_uri, :session, :join),
        mode: :call,
        args: %{member: anon_uri},
        ctx: %{caller: anon_uri, reply: :ignore}
      })
      |> case do
        :ok -> :ok
        {:ok, _} -> :ok
      end

    _ = Ezagent.ActionSet.Session.Membership.mount_participation_caps(session_uri, anon_uri)
    anon_uri
  end

  defp wait_for_page(session, caller, attempts \\ 150)

  defp wait_for_page(_session, _caller, 0),
    do: flunk("external snapshot never exposed an approved page")

  defp wait_for_page(session, caller, attempts) do
    case ExternalFeed.snapshot(session, caller) do
      {:ok, %{page: page} = snapshot} when not is_nil(page) ->
        snapshot

      _ ->
        Process.sleep(20)
        wait_for_page(session, caller, attempts - 1)
    end
  end

  defp find_session_template_uri!(template_name, workspace_name) do
    prefix =
      workspace_name
      |> Ezagent.URI.template(:session, "#{template_name}@")
      |> URI.to_string()

    Ezagent.KindRegistry.list_all()
    |> Enum.find_value(fn {uri_str, _pid} ->
      if String.starts_with?(uri_str, prefix), do: Ezagent.URI.new!(uri_str)
    end) ||
      flunk("expected live SessionTemplate with prefix #{prefix}")
  end

  defp template_hash(%URI{} = uri) do
    uri
    |> Ezagent.URI.name!()
    |> String.split("@", parts: 2)
    |> List.last()
  end

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
    workspace_conn(conn, "system")
  end

  defp workspace_conn(conn, workspace_name, entity_uri \\ nil) do
    entity_uri = entity_uri || Ezagent.Entity.User.admin_uri()

    conn
    |> Map.put(:host, "world.ezagent.chat")
    |> Plug.Test.init_test_session(%{
      "current_entity_uri" => URI.to_string(entity_uri),
      "current_workspace_uri" => URI.to_string(Ezagent.URI.workspace(workspace_name))
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
      _ -> ensure_default_world_session!()
    end
  end

  defp ensure_default_world_session! do
    workspace_uri = Ezagent.URI.workspace(:system)
    create = &Ezagent.Workspace.create_session/3

    case create.(
           workspace_uri,
           %{short_name: "main", template_name: "default"},
           %{
             caller: Ezagent.Entity.User.admin_uri(),
             caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()])
           }
         ) do
      {:ok, %{session_uri: %URI{} = uri}} -> uri
      _ -> Ezagent.URI.new!("session://system/default/main")
    end
  end

  defp session_cap(caller_uri, session_uri, action) do
    %Ezagent.Capability{
      kind: :session,
      behavior: Ezagent.ActionSet.Session,
      action: action,
      instance: session_uri,
      workspace_uri: Ezagent.URI.workspace(:system),
      granted_by: caller_uri,
      granted_at: DateTime.utc_now()
    }
  end

  defp matcher_targets_session?({:in_session, session_str}, session_str), do: true

  defp matcher_targets_session?({:and, items}, session_str) when is_list(items),
    do: Enum.any?(items, &matcher_targets_session?(&1, session_str))

  defp matcher_targets_session?({:or, items}, session_str) when is_list(items),
    do: Enum.any?(items, &matcher_targets_session?(&1, session_str))

  defp matcher_targets_session?({:not, matcher}, session_str),
    do: matcher_targets_session?(matcher, session_str)

  defp matcher_targets_session?(_, _), do: false
end
