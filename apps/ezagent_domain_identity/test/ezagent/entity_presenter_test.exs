defmodule Ezagent.EntityPresenterTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Entity.Profile
  alias Ezagent.EntityPresenter

  test "display/1 returns the profile name when present" do
    {:ok, _} = Profile.upsert(%{entity_uri: "entity://team-alpha/user/allen", display_name: "Allen Woods"})
    assert EntityPresenter.display("entity://team-alpha/user/allen") == "Allen Woods"
  end

  test "display/1 falls back to the URI path segment when no profile" do
    assert EntityPresenter.display("entity://system/user/admin") == "admin"
    assert EntityPresenter.display("entity://team-alpha/agent/echo") == "echo"
  end

  test "display/1 falls back to the raw string for an unparseable URI" do
    assert EntityPresenter.display("not a uri") == "not a uri"
  end

  test "display_many/1 batch-resolves, keyed by string, with fallbacks" do
    {:ok, _} = Profile.upsert(%{entity_uri: "entity://team-alpha/user/a", display_name: "Ay"})

    result = EntityPresenter.display_many(["entity://team-alpha/user/a", Ezagent.URI.new!("entity://team-alpha/agent/echo")])

    assert result == %{
             "entity://team-alpha/user/a" => "Ay",
             "entity://team-alpha/agent/echo" => "echo"
           }
  end
end
