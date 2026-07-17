defmodule Ezagent.World.ConversationActionsTest do
  use ExUnit.Case, async: true

  alias Ezagent.World.ConversationActions

  test "Session-Config UI actions project through the domain execute boundary" do
    source =
      File.read!(Path.expand("../../../lib/ezagent/world/conversation_actions.ex", __DIR__))

    assert source =~ "Ezagent.Session.Config.execute("
    refute source =~ "Ezagent.Orchestrator.Tools.Templates.save_template_as"
  end

  alias Ezagent.World.ConversationRoutingForm

  test "create_session_result converts create_session exits into errors" do
    workspace_uri = Ezagent.URI.workspace(:system)
    caller = Ezagent.Entity.User.admin_uri()

    assert {:error, {:create_session_exit, {:timeout, _}}} =
             ConversationActions.create_session_result(
               workspace_uri,
               caller,
               "world-pr4-timeout",
               "default",
               fn _workspace_uri, _params, _ctx -> exit({:timeout, self()}) end
             )
  end

  test "create_session_result passes the baseline workspace create context" do
    workspace_uri = Ezagent.URI.workspace(:system)
    caller = Ezagent.Entity.User.admin_uri()
    session_uri = Ezagent.URI.session("system", "default", "world-create-baseline")

    assert {:ok, ^session_uri} =
             ConversationActions.create_session_result(
               workspace_uri,
               caller,
               "world-create-baseline",
               "default",
               fn got_workspace_uri, got_params, got_ctx ->
                 assert got_workspace_uri == workspace_uri

                 assert got_params == %{
                          short_name: "world-create-baseline",
                          template_name: "default"
                        }

                 assert got_ctx == %{caller: caller, caps: MapSet.new()}

                 {:ok, %{session_uri: session_uri}}
               end
             )
  end

  describe "routing receiver form parsing" do
    test "normalizes role receivers to tagged resolver receivers" do
      assert [
               "entity://system/user/admin",
               {:role, "builder"}
             ] =
               ConversationRoutingForm.parse_receivers([
                 "entity://system/user/admin",
                 "role:builder"
               ])
    end

    test "keeps magic receivers and rejects empty role receivers" do
      assert ["$session_members"] =
               ConversationRoutingForm.parse_receivers(["$session_members", "role:"])
    end
  end

  # F3: every session-create failure must map to a non-empty operator-facing
  # message (so the sessions table shows a banner instead of silently dropping).
  describe "session_create_error_message/1 (F3 no-silent-drop)" do
    test "named reasons get friendly messages" do
      for reason <- [:short_name_required, :template_required, :invalid_workspace, :unauthorized] do
        msg = ConversationActions.session_create_error_message(reason)
        assert is_binary(msg) and msg != ""
      end
    end

    test "the F3 wrong-template default failure ({:invalid_template, _}) is explained" do
      msg = ConversationActions.session_create_error_message({:invalid_template, %{}})
      assert is_binary(msg) and msg != ""
      refute msg =~ "invalid_template"
    end

    test "an unknown reason still produces a non-empty message (never a silent drop)" do
      msg = ConversationActions.session_create_error_message(:some_unmapped_reason)
      assert is_binary(msg) and msg != ""
      assert msg =~ "联系 workspace founder"
      refute msg =~ "some_unmapped_reason"
    end

    test "unsupported Claude dev-channel errors get a concise operator message" do
      msg =
        ConversationActions.session_create_error_message(
          {:agent_grant_recipe_caps_failed,
           {:grant_failed, {:unsupported_claude_dev_channels, "/usr/bin/claude"}}}
        )

      assert msg =~ "Claude Code"
      assert msg =~ "不支持"
      refute msg =~ "agent_grant_recipe_caps_failed"
    end
  end

  # Regression: a session name with a space used to crash session URI parsing
  # ("URI parse failed at \":\": \"session://ezagent/hello/hello world\"").
  describe "session name sanitization (URI path-segment safety)" do
    test "collapses whitespace to '-' so a spaced name builds a valid session URI" do
      assert ConversationActions.sanitize_short_name("hello world") == "hello-world"
      assert ConversationActions.sanitize_short_name("  multi   space  ") == "multi-space"

      uri =
        Ezagent.URI.session(
          "ezagent",
          "hello",
          ConversationActions.sanitize_short_name("hello world")
        )

      assert %URI{} = uri
      assert URI.to_string(uri) == "session://ezagent/hello/hello-world"
    end

    test "CJK display names use canonical percent-encoded URI segments" do
      display_name = "客服会话"
      assert ConversationActions.valid_session_name?(display_name)

      segment = ConversationActions.session_uri_segment(display_name)
      assert segment == URI.encode(display_name, &URI.char_unreserved?/1)

      uri = Ezagent.URI.session("ezagent", "hello", segment)
      assert URI.to_string(uri) =~ segment
      assert Ezagent.World.ConversationSessionState.session_display_name(uri) == display_name
      assert_raise ArgumentError, fn -> Ezagent.URI.session("ezagent", "hello", display_name) end
    end

    test "valid_session_name?/1 accepts product characters and rejects reserved ones" do
      for ok <- ["客服会话", "客服-会话", "hello-world", "abc_123", "Session1"] do
        assert ConversationActions.valid_session_name?(ok), "expected #{ok} allowed"
      end

      for bad <- ["a/b", "a:b", "a?b", "a#b", "a@b", "a[b", "a b", "a.b", "a~b", ""] do
        refute ConversationActions.valid_session_name?(bad),
               "expected #{inspect(bad)} rejected"
      end
    end

    test "session name errors match the Chinese 2-30 character form rule" do
      assert ConversationActions.session_create_error_message(:short_name_too_short) =~
               "至少需要 2 个字符"

      assert ConversationActions.session_create_error_message(:short_name_too_long) =~
               "不能超过 30 个字符"

      msg = ConversationActions.session_create_error_message(:invalid_short_name)
      assert msg =~ "中文"
      refute msg =~ "invalid_short_name"
    end
  end

  # Stage 1 — switch_view whitelist is the caller-aware registry set, not the old
  # hard-coded ["chat","pty","page"]. A visible (enumerated) view id is accepted;
  # anything else is rejected `error:bad_view`, same-source as the tab visibility.
  describe "switch_view/3 (dynamic registry whitelist)" do
    setup do
      :ok = Ezagent.UI.SessionViewRegistry.init()
      :ok = Ezagent.UI.SessionViewRegistry.register(Ezagent.World.ConversationView)
      %{session: Ezagent.URI.session("acme", "default", "sw1")}
    end

    test "accepts an enumerated view id and rejects an unknown one", %{session: session} do
      socket = build_socket(current_entity_uri: Ezagent.URI.user("acme", "admin"))

      assert {:noreply, ok_socket} =
               ConversationActions.switch_view(socket, session, "conversation")

      assert ok_socket.assigns.world_state["active_view"] == "conversation"

      assert {:noreply, bad_socket} =
               ConversationActions.switch_view(socket, session, "does_not_exist")

      assert bad_socket.assigns.last_dispatch_status == "error:bad_view"
    end
  end

  # Minimal LiveView socket stub: enough assigns for switch_view + push_world_state
  # (which merges "active_view" into :world_state and pushes a "world:state" event).
  defp build_socket(assigns) do
    base =
      Phoenix.Component.assign(%Phoenix.LiveView.Socket{}, :world_state, %{})

    Enum.reduce(assigns, base, fn {k, v}, acc -> Phoenix.Component.assign(acc, k, v) end)
  end
end
