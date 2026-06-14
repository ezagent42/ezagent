defmodule Ezagent.Template.GenericSessionTest do
  use ExUnit.Case, async: false

  alias Ezagent.Template.GenericSession

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, {:shared, self()})
    :ok
  end

  describe "template_name/0" do
    test "returns the stable id" do
      assert GenericSession.template_name() == "session.generic"
    end
  end

  describe "validate/1" do
    test "accepts well-formed template data" do
      assert :ok =
               GenericSession.validate(%{
                 "class" => "session.generic",
                 "session_name" => "demo",
                 "members" => ["entity://system/user/admin", "entity://team-alpha/agent/test_x"]
               })
    end

    test "accepts data without members (defaults to empty)" do
      assert :ok =
               GenericSession.validate(%{
                 "class" => "session.generic",
                 "session_name" => "demo"
               })
    end

    test "rejects wrong class" do
      assert {:error, {:wrong_class, "other"}} =
               GenericSession.validate(%{
                 "class" => "other",
                 "session_name" => "demo"
               })
    end

    test "rejects missing session_name" do
      assert {:error, :missing_or_empty_session_name} =
               GenericSession.validate(%{
                 "class" => "session.generic"
               })
    end

    test "rejects empty session_name" do
      assert {:error, :missing_or_empty_session_name} =
               GenericSession.validate(%{
                 "class" => "session.generic",
                 "session_name" => ""
               })
    end

    test "rejects non-URI member" do
      assert {:error, {:invalid_member, "not-a-uri", _}} =
               GenericSession.validate(%{
                 "class" => "session.generic",
                 "session_name" => "demo",
                 "members" => ["not-a-uri"]
               })
    end

    test "rejects unknown top-level keys" do
      assert {:error, {:unknown_keys, ["extra"]}} =
               GenericSession.validate(%{
                 "class" => "session.generic",
                 "session_name" => "demo",
                 "extra" => "value"
               })
    end
  end

  describe "instantiate/3" do
    test "spawns a Session at session://<workspace>/generic/<name> + dispatches join for each member" do
      session_name = "gs-test-#{System.unique_integer([:positive])}"
      workspace_uri = Ezagent.URI.new!("workspace://test")

      tmpl = %{
        "class" => "session.generic",
        "session_name" => session_name,
        "members" => ["entity://system/user/admin"]
      }

      assert {:ok, [session_uri]} =
               GenericSession.instantiate("main", tmpl, workspace_uri)

      assert URI.to_string(session_uri) == "session://test/generic/#{session_name}"

      # Session Kind alive in KindRegistry
      assert {:ok, _pid} = Ezagent.KindRegistry.lookup(session_uri)
    end

    test "is idempotent — re-call returns same URI without crash" do
      session_name = "gs-idem-#{System.unique_integer([:positive])}"
      workspace_uri = Ezagent.URI.new!("workspace://test")

      tmpl = %{
        "class" => "session.generic",
        "session_name" => session_name,
        "members" => []
      }

      assert {:ok, [first_uri]} = GenericSession.instantiate("main", tmpl, workspace_uri)
      assert {:ok, [^first_uri]} = GenericSession.instantiate("main", tmpl, workspace_uri)
    end
  end
end
