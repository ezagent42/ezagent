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
end
