defmodule Ezagent.Socialware.Demo.HelloTest do
  use ExUnit.Case, async: true

  alias Ezagent.Socialware.Demo.Hello

  test "default manifest is the declarative hello reference routing shape" do
    attrs = Hello.manifest_attrs()

    assert Enum.sort(Enum.map(attrs["roles"], & &1["role_name"])) == [
             "builder",
             "responser",
             "viewer"
           ]

    assert %{"role_name" => "viewer", "fill" => "human"} in attrs["roles"]

    assert [
             %{
               "matcher" => %{"type" => "from_role", "arg" => "viewer"},
               "receivers" => ["responser"]
             },
             %{
               "matcher" => %{
                 "type" => "and",
                 "items" => [
                   %{"type" => "from_role", "arg" => "responser"},
                   %{"type" => "text_matches", "arg" => "^\\[need-build\\]"}
                 ]
               },
               "receivers" => ["builder"]
             }
           ] = attrs["routing_rules"]
  end
end
