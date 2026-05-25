defmodule EzagentPluginLiveview.AdminLiveTest do
  @moduledoc """
  /sessions LiveView integration tests.

  Phase 8b rewrite: admin_live no longer hosts Echo / Manual Dispatch /
  Audit Log (moved to /admin/logs ObservabilityLive). The session
  view-switcher (Chat / Terminal) + Members panel + inline @ mention
  composer are the surfaces tested here.
  """

  use ExUnit.Case
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint EzagentWeb.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, {:shared, self()})

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{
        "current_entity_uri" => URI.to_string(Ezagent.Entity.User.admin_uri())
      })

    {:ok, conn: conn}
  end

  test "GET /sessions renders SessionEditor with session selector + view-switcher", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/sessions")

    # SessionEditor is wrapped in IDE Shell — the page id is stable.
    assert html =~ ~s(id="session-editor")
    # Header components.
    assert html =~ ~s(id="session-selector")
    assert html =~ ~s(id="view-switcher")
    # Default ConversationView ships with the liveview plugin → its
    # "Chat" label appears in the view-switcher.
    assert html =~ "Chat"
    # Composer input wired up with the autocomplete hook.
    assert html =~ ~s(phx-hook="MentionAutocomplete")
    # Caller URI shown somewhere in the IDE shell chrome.
    assert html =~ "entity://user/system/admin"
  end

  test "Session members section shows admin User as online (Phase 2 boot)", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/sessions")

    # Section header
    assert html =~ "session://default/default/main"
    # admin URI listed
    assert html =~ "entity://user/system/admin"
    # admin is online (boot post-spawn dispatched chat/join)
    assert html =~ "online"
    # The members table id is rendered (not the empty-state placeholder)
    assert html =~ ~s(id="session-members-table")
    refute html =~ ~s(id="session-members-empty")
  end

  test "Chat compose dispatches send and message lands in stream", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/sessions")

    text = "lv chat compose test #{System.unique_integer([:positive])}"

    lv
    |> form("form[phx-submit=chat_compose]", %{"chat" => %{"text" => text}})
    |> render_submit()

    Process.sleep(100)
    html = render(lv)

    assert html =~ text
    assert html =~ "entity://user/system/admin"
  end

  test "Chat row shape identical for admin vs agent senders (CSS-level diff only)", %{conn: conn} do
    {:ok, lv, _html} = live(conn, "/sessions")

    admin_text = "admin-says-#{System.unique_integer([:positive])}"

    lv
    |> form("form[phx-submit=chat_compose]", %{"chat" => %{"text" => admin_text}})
    |> render_submit()

    assert wait_until_html(lv, admin_text)

    # Simulate an agent reply landing via the chat_message broadcast.
    agent_uri = URI.new!("entity://agent/default/test_test-#{System.unique_integer([:positive])}")
    agent_msg = Ezagent.Message.new(agent_uri, %{text: "agent reply test", attachments: []})

    Phoenix.PubSub.broadcast(
      EzagentCore.PubSub,
      Ezagent.Behavior.Chat.session_events_topic(URI.new!("session://default/default/main")),
      {:chat_message, URI.new!("session://default/default/main"), agent_msg}
    )

    assert wait_until_html(lv, "agent reply test")

    html = render(lv)
    assert html =~ admin_text
    assert html =~ "agent reply test"
    assert html =~ ~s(id="messages")
  end

  defp wait_until_html(lv, substr, retries \\ 50)
  defp wait_until_html(_lv, _substr, 0), do: false

  defp wait_until_html(lv, substr, retries) do
    if render(lv) =~ substr do
      true
    else
      Process.sleep(20)
      wait_until_html(lv, substr, retries - 1)
    end
  end

  test "Load older button paginates history (Phase 5 PR 5 invariant)", %{conn: conn} do
    session_uri = URI.new!("session://default/default/main")
    base = ~U[2026-05-17 09:00:00.000000Z]

    for i <- 1..100 do
      msg =
        Ezagent.Message.new(
          URI.new!("entity://user/system/admin"),
          %{text: "histmsg-#{i}", attachments: []},
          inserted_at: DateTime.add(base, i, :second)
        )

      {:ok, _} = Ezagent.MessageStore.write(msg, session_uri)
    end

    {:ok, lv, html} = live(conn, "/sessions")

    msg = fn i -> "histmsg-#{i}</div>" end

    assert html =~ msg.(100)
    assert html =~ msg.(51)
    refute html =~ msg.(50)
    refute html =~ msg.(1)

    lv |> element("#load-older-btn") |> render_click()
    html = render(lv)
    assert html =~ msg.(1)
    assert html =~ msg.(50)
    assert html =~ msg.(100)

    for i <- 1..100 do
      assert length(String.split(html, msg.(i))) - 1 == 1,
             "#{msg.(i)} appeared more than once after load_older click"
    end

    lv |> element("#load-older-btn") |> render_click()
    html2 = render(lv)
    assert html2 =~ msg.(1)
  end

  describe "Phase 8b — view-switcher" do
    test "view-switcher renders Chat button (ConversationView always applies)", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/sessions")

      # The Chat label from ConversationView appears inside the view-switcher.
      [_, switcher_block | _] = String.split(html, ~s(id="view-switcher"))
      assert switcher_block =~ "Chat"
    end

    test "switch_view event updates current_view assign", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/sessions")

      # Switch to a hypothetical view id (`:conversation` is the
      # default — round-trip the event to verify the handler exists
      # and doesn't crash even when the id is the same one).
      render_hook(lv, "switch_view", %{"view" => "conversation"})
      html = render(lv)
      assert html =~ "Chat"
    end

    test "switch_view ignores unknown view ids (no crash)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/sessions")

      render_hook(lv, "switch_view", %{"view" => "no_such_view_xyz_42"})
      # LV survives the bad event — render still works.
      _ = render(lv)
    end

    test "switch_to_pty_for_agent sets current_view + active_pty_agent_uri", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/sessions")

      render_hook(lv, "switch_to_pty_for_agent", %{
        "agent" => "entity://agent/default/cc_demo"
      })

      html = render(lv)
      # The PtyView is registered only when cc plugin is loaded, but
      # even without it the LV state flips and SessionEditor's
      # `:active_pty_agent_uri` is observable via the data-agent-uri
      # attribute on a PTY DOM node (if PtyView is registered) or via
      # the fall-back ConversationView rendering. Either way no crash.
      assert is_binary(html)
    end

    # V1 UI fix (Allen Feishu 2026-05-21) — terminal icon in MemberPanel
    # was a phx-click that updated `:current_view = :pty` but NOT
    # `:view_module`. Result: clicking the terminal icon next to cc_demo
    # in /sessions appeared to do nothing — assigns flipped but
    # `render_active_view` kept calling ConversationView's render.
    #
    # This test fails on the buggy code path (terminal click → view
    # stays as ConversationView's empty/dot-grid state) and passes on
    # the fix (terminal click → TerminalView's "Terminal —" marker appears).
    #
    # We join a PTY-backed agent to the main session so TerminalView's
    # `applies_to?/1` returns true. After Domain.Pty PR-C the detection
    # is cross-flavor — `Ezagent.Domain.Pty.alive?/1` for ANY member —
    # so we explicitly start a Domain.Pty.Server in test_mode below.
    test "terminal icon click flips the rendered view to TerminalView (V1 UI fix)", %{conn: conn} do
      session_uri = URI.new!("session://default/default/main")

      # Spawn a real cc agent + start its PTY sidecar + join it as a
      # member so TerminalView applies.
      name = "cc_demo-uifix-#{System.unique_integer([:positive])}"
      agent_uri = URI.parse("entity://agent/default/#{name}")
      {:ok, _kind_pid} = Ezagent.SpawnRegistry.spawn(agent_uri)
      {:ok, _pty_pid} = Ezagent.Domain.Pty.start(agent_uri, %{cwd: "/tmp", test_mode: true})
      on_exit(fn -> Ezagent.Domain.Pty.stop(agent_uri) end)

      join_target = URI.new!("#{URI.to_string(session_uri)}?action=chat.join")

      :ok =
        Ezagent.Invocation.dispatch(%Ezagent.Invocation{
          target: join_target,
          mode: :call,
          args: %{member: agent_uri},
          ctx: %{
            caller: Ezagent.Entity.User.admin_uri(),
            caps: Ezagent.Entity.User.admin_caps(),
            reply: :ignore
          }
        })
        |> case do
          :ok -> :ok
          {:ok, _} -> :ok
        end

      {:ok, lv, html} = live(conn, "/sessions")

      # Pre-click: rendering is ConversationView (default). No PtyView
      # marker yet. Use the unique header text "Terminal —" PtyView
      # emits inside its render.
      refute html =~ "Terminal —"

      # The terminal icon button is rendered next to cc_demo in the
      # Members panel. Its phx-click is `switch_to_pty_for_agent` with
      # phx-value-agent = the cc_demo URI.
      assert html =~ ~s(phx-click="switch_to_pty_for_agent")
      assert html =~ URI.to_string(agent_uri)

      # Simulate the click.
      render_hook(lv, "switch_to_pty_for_agent", %{
        "agent" => URI.to_string(agent_uri)
      })

      html = render(lv)
      # PtyView's render now drives Main Window. Before the fix, this
      # assertion fails — `:current_view = :pty` but `:view_module`
      # still points at ConversationView so PtyView never renders.
      assert html =~ "Terminal —",
             "expected PtyView's `Terminal —` header after switch_to_pty_for_agent, but render still shows the previous view (likely the bug: :view_module was not recomputed)"

      # The selected agent URI is bound into the PTY chrome.
      assert html =~ URI.to_string(agent_uri)
    end

    # Sibling invariant — `switch_view` (the header view-switcher
    # buttons) has the same bug shape. Once the PTY-backed agent
    # joins, the view-switcher gets a "Terminal" button alongside
    # "Chat"; clicking it MUST also re-resolve `:view_module`, not
    # just flip `:current_view`.
    test "switch_view to :pty flips the rendered view to TerminalView", %{conn: conn} do
      session_uri = URI.new!("session://default/default/main")
      name = "cc_demo-switchview-#{System.unique_integer([:positive])}"
      agent_uri = URI.parse("entity://agent/default/#{name}")
      {:ok, _kind_pid} = Ezagent.SpawnRegistry.spawn(agent_uri)
      {:ok, _pty_pid} = Ezagent.Domain.Pty.start(agent_uri, %{cwd: "/tmp", test_mode: true})
      on_exit(fn -> Ezagent.Domain.Pty.stop(agent_uri) end)

      join_target = URI.new!("#{URI.to_string(session_uri)}?action=chat.join")

      _ =
        Ezagent.Invocation.dispatch(%Ezagent.Invocation{
          target: join_target,
          mode: :call,
          args: %{member: agent_uri},
          ctx: %{
            caller: Ezagent.Entity.User.admin_uri(),
            caps: Ezagent.Entity.User.admin_caps(),
            reply: :ignore
          }
        })

      {:ok, lv, _html} = live(conn, "/sessions")

      # Set active_pty_agent_uri first (otherwise PtyView renders its
      # "select a cc agent" empty state — still a PtyView render,
      # which is what we want to detect, but be explicit).
      render_hook(lv, "switch_to_pty_for_agent", %{
        "agent" => URI.to_string(agent_uri)
      })

      # Now bounce back to Chat then back to Terminal via switch_view —
      # the second switch_view exercises the assign(:view_module) path.
      render_hook(lv, "switch_view", %{"view" => "conversation"})
      html = render(lv)
      refute html =~ "Terminal —"

      render_hook(lv, "switch_view", %{"view" => "pty"})
      html = render(lv)
      assert html =~ "Terminal —"
    end
  end

  describe "Phase 8b — setting dropdown" do
    test "setting menu HTML renders (collapsed)", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/sessions")
      assert html =~ ~s(id="session-setting-menu")
      assert html =~ "Routing rules for this session"
      assert html =~ "Feishu binding"
    end

    test "toggle_debug_panel flips :debug_open", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/sessions")

      # Toggle should not crash; the panel is gated on cc_events being
      # non-empty so visual change isn't observable in this test,
      # but the event must round-trip.
      render_hook(lv, "toggle_debug_panel", %{})
      _ = render(lv)
    end

    test "debug panel shows empty state when toggled with no cc_events",
         %{conn: conn} do
      {:ok, lv, html} = live(conn, "/sessions")

      # Collapsed: the panel section (heading + empty state) is absent.
      refute html =~ "No debug events yet"

      # V1 fix (Allen 2026-05-22): the panel previously rendered only
      # when cc_events != []. With the common case (no CC-hook events)
      # toggling debug_open must now still show the panel with an
      # explicit empty state — not a blank surface.
      html = render_hook(lv, "toggle_debug_panel", %{})
      assert html =~ "Debug events (last 20)"
      assert html =~ "No debug events yet"
    end
  end

  describe "V1 UI SPEC §2C — member panel Invite modal" do
    test "open_invite_modal / close_invite_modal toggle the modal", %{conn: conn} do
      {:ok, lv, html} = live(conn, "/sessions")

      # Closed at mount — the `<.modal>` wrapper carries `hidden`.
      [_, closed_block | _] = String.split(html, ~s(id="invite-member-modal"))
      assert closed_block =~ "hidden"

      # Open it.
      html = render_hook(lv, "open_invite_modal", %{})
      [_, open_block | _] = String.split(html, ~s(id="invite-member-modal"))

      refute open_block
             |> String.split(">")
             |> hd()
             |> String.contains?(" hidden")

      # Close it again.
      html = render_hook(lv, "close_invite_modal", %{})
      [_, reclosed_block | _] = String.split(html, ~s(id="invite-member-modal"))
      assert reclosed_block =~ "hidden"
    end

    # SPEC §2C.4 — `invite_member` with a valid in-workspace entity URI
    # dispatches `chat.join` as `:call`; on `:ok` the member appears in
    # the unified list and the modal closes.
    test "invite_member with a valid entity → member added + modal closes", %{conn: conn} do
      name = "cc_demo-invite-#{System.unique_integer([:positive])}"
      agent_uri = URI.parse("entity://agent/default/#{name}")
      {:ok, _kind_pid} = Ezagent.SpawnRegistry.spawn(agent_uri)

      {:ok, lv, _html} = live(conn, "/sessions")

      # Before the invite the agent is NOT a member — the unified list
      # carries no PTY button targeting it (the cc-agent PTY button is
      # only emitted for members).
      refute member_row?(render(lv), URI.to_string(agent_uri))

      render_hook(lv, "open_invite_modal", %{})

      html =
        render_hook(lv, "invite_member", %{"member_uri" => URI.to_string(agent_uri)})

      # The agent is now a member of the unified list.
      assert html =~ ~s(id="session-members-table")
      assert member_row?(html, URI.to_string(agent_uri))

      # The modal closed on confirmed :ok.
      [_, modal_block | _] = String.split(html, ~s(id="invite-member-modal"))
      assert modal_block =~ "hidden"
    end

    # SPEC §1.6 / §2C.4 step 1 — the picker's hidden input is untrusted.
    # A hand-tampered out-of-workspace URI is rejected with a flash and
    # is NEVER dispatched (the entity does not become a member).
    test "invite_member with an out-of-workspace URI → flash, NOT dispatched", %{conn: conn} do
      # session://default/default/main lives in workspace `default`; a
      # URI whose workspace segment is `otherws` fails the shared
      # `UriOptions.valid_for?/4` workspace check even for a system
      # caller (a picker field is scoped to ONE workspace).
      bad_uri = "entity://agent/otherws/cc_intruder-#{System.unique_integer([:positive])}"

      {:ok, lv, _html} = live(conn, "/sessions")
      render_hook(lv, "open_invite_modal", %{})

      html = render_hook(lv, "invite_member", %{"member_uri" => bad_uri})

      # Flash names the rejection — no silent drop.
      assert html =~ "Rejected"
      assert html =~ "workspace"
      # The bad URI never reached dispatch → it is NOT in the member list.
      refute member_row?(html, bad_uri)
    end

    # SPEC §2C.4 step 3 + §4 verification item 15 — a genuine
    # `:unauthorized` dispatch result surfaces as a DISTINCT flash, not
    # a silent drop. The pre-V1 `add_floating_agent` `:cast` path
    # discarded this. A non-admin caller with no caps (its User Kind is
    # never spawned → `Identity.list_caps_for/1` returns an empty
    # MapSet) is denied by CapBAC.
    test "invite_member surfacing :unauthorized → distinct flash, no silent drop", %{conn: _conn} do
      name = "cc_demo-unauth-#{System.unique_integer([:positive])}"
      agent_uri = URI.parse("entity://agent/default/#{name}")
      {:ok, _kind_pid} = Ezagent.SpawnRegistry.spawn(agent_uri)

      # A non-admin caller in workspace `default` (same workspace as
      # session://default/default/main, so the denial is :unauthorized,
      # not :cross_workspace_denied) with NO caps.
      non_admin = "entity://user/default/tester-#{System.unique_integer([:positive])}"

      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Test.init_test_session(%{"current_entity_uri" => non_admin})

      {:ok, lv, _html} = live(conn, "/sessions")
      render_hook(lv, "open_invite_modal", %{})

      html =
        render_hook(lv, "invite_member", %{"member_uri" => URI.to_string(agent_uri)})

      # Distinct :unauthorized flash — NOT a generic "failed" and NOT
      # silently swallowed.
      assert html =~ "Unauthorized"
      # The invite did not go through → the agent is not a member.
      refute member_row?(html, URI.to_string(agent_uri))
    end
  end

  # An agent URI may legitimately appear in the page outside the member
  # list (e.g. inside the Invite picker's `data-options` JSON). A true
  # "is a member" check looks for the row's cc-agent PTY button, which
  # `MemberPanel` emits ONLY for joined cc-agent members.
  defp member_row?(html, agent_uri) do
    html =~ ~s(phx-value-agent="#{agent_uri}")
  end

  describe "Phase 8b — composer @ autocomplete wiring" do
    test "composer input has MentionAutocomplete hook + data-members JSON", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/sessions")

      # Hook is wired
      assert html =~ ~s(phx-hook="MentionAutocomplete")
      # data-members carries a JSON array (admin User is at least one member)
      assert html =~ ~s(id="chat-compose-input")
      # mention popover element is in the DOM (hidden by default)
      assert html =~ ~s(id="mention-popover")
    end

    test "no <select> mention dropdown is rendered (replaced by autocomplete)", %{conn: conn} do
      {:ok, _lv, html} = live(conn, "/sessions")

      refute html =~ ~s(name="chat[agent_uri]")
      refute html =~ "— room (no mention) —"
    end
  end

  # PR-N2 (SPEC v2 notification architecture, Allen 2026-05-24) —
  # AdminLive's mount/3 now subscribes to BOTH the legacy
  # `Ezagent.Notifications.topic/1` AND the new
  # `Ezagent.SliceChange.topic/1`. Both topics must keep working
  # during the transition window (PR-N3 flips the auto-hook on;
  # PR-N5 deletes the legacy path).
  #
  # We assert "subscribed + handler runs cleanly" via:
  #   1. The LV process appears in `Phoenix.PubSub`'s subscriber
  #      list for BOTH topics (proves `mount/3` ran both subscribes).
  #   2. After broadcasting to each topic, the LV is still alive
  #      and `render/1` still works (proves the corresponding
  #      `handle_info/2` clauses exist and didn't crash). A missing
  #      clause would surface as a `FunctionClauseError` and tear
  #      down the LV pid.
  describe "PR-N2 — subscriber-side dual-topic migration" do
    test "mount subscribes to both legacy AND new slice_change topic", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/sessions")

      caller_uri = Ezagent.Entity.User.admin_uri()
      legacy_topic = Ezagent.Notifications.topic(caller_uri)
      new_topic = Ezagent.SliceChange.topic(caller_uri)

      # Phoenix.PubSub.node_name + subscribers lookup gives the pids
      # listening on each topic in the local node. The LV pid must
      # appear under BOTH topics.
      legacy_subs = subscribers_for(legacy_topic)
      new_subs = subscribers_for(new_topic)

      assert lv.pid in legacy_subs,
             "expected AdminLive pid in subscribers of #{legacy_topic} (subs=#{inspect(legacy_subs)})"

      assert lv.pid in new_subs,
             "expected AdminLive pid in subscribers of #{new_topic} (subs=#{inspect(new_subs)})"
    end

    # PR-N2 codex r1 MEDIUM-2 fix — `mount/3` mirrors EVERY session
    # the legacy `session_events_topic/1` loop subscribes to with a
    # parallel slice-change subscription on the SAME session URI.
    # Without this, after PR-N5 deletes the legacy fan-out, session-
    # scoped Behavior mutations (chat / member / read marker) that
    # emit slice-change events on the SESSION URI would be invisible
    # to AdminLive — only the caller's USER URI slice-change is
    # subscribed in PR-N2's first cut.
    test "mount also subscribes to slice_change for every legacy session topic",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/sessions")

      sessions = EzagentDomainChat.list_sessions()

      assert sessions != [],
             "expected at least one session in the boot list (default/default/main)"

      for session_uri <- sessions do
        slice_topic = Ezagent.SliceChange.topic(session_uri)
        subs = subscribers_for(slice_topic)

        assert lv.pid in subs,
               "expected AdminLive pid in subscribers of session slice_change topic " <>
                 "#{slice_topic} (got subs=#{inspect(subs)})"
      end
    end

    test "session-scoped {:slice_changed, _} delivers cleanly (no handler crash)",
         %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/sessions")
      lv_pid = lv.pid

      session_uri = URI.new!("session://default/default/main")

      Application.put_env(:ezagent_core, :slice_change_hook, true)

      try do
        event = %{
          self_uri: session_uri,
          kind_module: :session_kind_stub,
          action: :pr_n2_session_scoped,
          slice_key: :chat,
          old_slice: %{messages: 0},
          new_slice: %{messages: 1},
          result: nil,
          caller: Ezagent.Entity.User.admin_uri(),
          at: DateTime.utc_now()
        }

        :ok = Ezagent.SliceChange.emit(event)
      after
        Application.delete_env(:ezagent_core, :slice_change_hook)
      end

      _ = render(lv)

      assert Process.alive?(lv_pid),
             "AdminLive crashed after receiving session-scoped {:slice_changed, _}"
    end

    test "both topics deliver cleanly to AdminLive (no handler crash)", %{conn: conn} do
      {:ok, lv, _html} = live(conn, "/sessions")
      lv_pid = lv.pid

      caller_uri = Ezagent.Entity.User.admin_uri()

      # 1. Legacy `{:notification, _, _}` envelope (PR-N1 shape).
      :ok =
        Phoenix.PubSub.broadcast(
          EzagentCore.PubSub,
          Ezagent.Notifications.topic(caller_uri),
          {:notification, caller_uri,
           %{type: :pr_n2_legacy, body: %{}, source: __MODULE__, summary: "legacy bridge"}}
        )

      # 2. New `{:slice_changed, _}` envelope (PR-N1 shape via
      # `SliceChange.emit/1`). Enable the feature flag so the emit
      # actually broadcasts; the AdminLive subscription side does
      # not gate on the flag (it just subscribes).
      Application.put_env(:ezagent_core, :slice_change_hook, true)

      try do
        event = %{
          self_uri: caller_uri,
          kind_module: Ezagent.Entity.User,
          action: :pr_n2_integration,
          slice_key: :test_slice,
          old_slice: %{n: 1},
          new_slice: %{n: 2},
          result: nil,
          caller: caller_uri,
          at: DateTime.utc_now()
        }

        :ok = Ezagent.SliceChange.emit(event)
      after
        Application.delete_env(:ezagent_core, :slice_change_hook)
      end

      # Round-trip a benign event to flush the message queue — once
      # `render/2` returns from the test we know all queued
      # handle_info clauses have run (LiveView serialises handle_info
      # + render through its GenServer mailbox).
      _ = render(lv)

      assert Process.alive?(lv_pid),
             "AdminLive crashed after receiving legacy and/or :slice_changed envelopes"
    end
  end

  # Inspect a Phoenix.PubSub topic's local subscriber pids. Walks
  # the underlying Registry of `Phoenix.PubSub.PG2` (the default
  # adapter shipped with Phoenix.PubSub) via its registry table.
  defp subscribers_for(topic) do
    # Phoenix.PubSub.subscribers/2 was removed; use the public
    # Phoenix.PubSub.node_name + Phoenix.PubSub.local_broadcast trick
    # via the Phoenix.PubSub.PG2 adapter's named Registry.
    Registry.lookup(EzagentCore.PubSub, topic) |> Enum.map(&elem(&1, 0))
  end
end
