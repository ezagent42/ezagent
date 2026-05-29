defmodule EzagentPluginLoom.TempUserTest do
  use ExUnit.Case, async: true

  alias EzagentPluginLoom.TempUser

  describe "temp_uri/1" do
    test "builds a canonical entity://user/<ws>/tmp_<id> URI" do
      uri = TempUser.temp_uri("system")
      assert %URI{scheme: "entity", host: "user", path: "/system/" <> name} = uri
      assert String.starts_with?(name, "tmp_")
    end

    test "two calls produce distinct ids (per-visitor uniqueness)" do
      refute URI.to_string(TempUser.temp_uri("system")) ==
               URI.to_string(TempUser.temp_uri("system"))
    end

    test "honors the workspace segment" do
      uri = TempUser.temp_uri("team-alpha")
      assert uri.path =~ ~r{^/team-alpha/tmp_}
    end
  end
end
