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
end
