defmodule Ezagent.World.ConversationActionsTest do
  use ExUnit.Case, async: true

  alias Ezagent.World.ConversationActions

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
    end
  end

  # Regression: a session name with a space used to crash session URI parsing
  # ("URI parse failed at \":\": \"session://ezagent/hello/hello world\"").
  describe "session name sanitization (URI path-segment safety)" do
    test "collapses whitespace to '-' so a spaced name builds a valid session URI" do
      assert ConversationActions.sanitize_short_name("hello world") == "hello-world"
      assert ConversationActions.sanitize_short_name("  multi   space  ") == "multi-space"

      uri = Ezagent.URI.session("ezagent", "hello", ConversationActions.sanitize_short_name("hello world"))
      assert %URI{} = uri
      assert URI.to_string(uri) == "session://ezagent/hello/hello-world"
    end

    test "CJK / reserved names are rejected cleanly (Ezagent.URI parses strictly)" do
      # Ezagent.URI.new! rejects raw CJK in a segment, so a CJK name must be caught
      # by uri_safe_short_name?/1 (→ :invalid_short_name) rather than crash the build.
      refute ConversationActions.uri_safe_short_name?("客服-会话")
      assert_raise ArgumentError, fn -> Ezagent.URI.session("ezagent", "hello", "客服-会话") end
    end

    test "uri_safe_short_name?/1 allows the URI unreserved set, rejects the rest" do
      for ok <- ["hello-world", "multi-space", "abc_123", "a.b~c", "Session1"] do
        assert ConversationActions.uri_safe_short_name?(ok), "expected #{ok} allowed"
      end

      for bad <- ["a/b", "a:b", "a?b", "a#b", "a@b", "a[b", "a b", "客服", ""] do
        refute ConversationActions.uri_safe_short_name?(bad), "expected #{inspect(bad)} rejected"
      end
    end

    test ":invalid_short_name maps to a friendly, non-empty message" do
      msg = ConversationActions.session_create_error_message(:invalid_short_name)
      assert is_binary(msg) and msg != ""
    end
  end
end
