defmodule EzagentPluginLiveview.Admin.SessionContextTest do
  use ExUnit.Case, async: true

  alias EzagentPluginLiveview.Admin.SessionContext

  describe "default_main_session_uri/1" do
    test "derives the canonical main session from the current workspace" do
      assert SessionContext.default_main_session_uri(URI.new!("workspace://team-alpha")) ==
               URI.new!("session://team-alpha/default/main")
    end

    test "falls back to the system main session when no workspace is assigned" do
      assert SessionContext.default_main_session_uri(nil) ==
               URI.new!("session://system/default/main")
    end
  end

  describe "parse_mentions/2" do
    test "keeps existing bare-name mention behavior in the extracted module" do
      members = [
        %{
          "uri" => "entity://team-alpha/agent/cc_e2e_final",
          "display_name" => "Claude"
        }
      ]

      assert [uri] = SessionContext.parse_mentions("@cc_e2e_final", members)
      assert URI.to_string(uri) == "entity://team-alpha/agent/cc_e2e_final"
    end
  end
end
