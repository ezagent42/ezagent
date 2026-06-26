defmodule EzagentPluginHello.Template.HelloSessionTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Workspace
  alias EzagentPluginHello.Template.HelloSession

  describe "validate/1" do
    test "accepts a well-formed session.hello template" do
      assert :ok = HelloSession.validate(%{"class" => "session.hello", "session_name" => "main"})
    end

    test "rejects wrong class / missing fields / non-map" do
      assert {:error, {:wrong_class, "session.other"}} =
               HelloSession.validate(%{"class" => "session.other", "session_name" => "x"})

      assert {:error, :missing_class_field} = HelloSession.validate(%{"session_name" => "x"})

      assert {:error, :missing_session_name} =
               HelloSession.validate(%{"class" => "session.hello"})

      assert {:error, :not_a_map} = HelloSession.validate("nope")
    end
  end

  describe "instantiate/3" do
    test "stands up a creatable hello app: session + joined builder member" do
      ws = "hello-tmpl-#{System.unique_integer([:positive])}"
      {:ok, _} = Workspace.create(ws, %{})
      workspace_uri = Ezagent.URI.workspace(ws)
      tmpl = %{"class" => "session.hello", "session_name" => "main"}

      assert {:ok, [session_uri], %{fresh?: true, vertical: :hello}} =
               HelloSession.instantiate("session.hello", tmpl, workspace_uri)

      assert session_uri == Ezagent.URI.session(ws, :hello, "main")

      # The builder is live and joined as a normal session member.
      builder_uri = Ezagent.URI.entity(ws, :agent, "hello_main")
      assert {:ok, _pid} = Ezagent.KindRegistry.lookup(builder_uri)

      assert %{^builder_uri => %{role_name: "builder"}} =
               Ezagent.Orchestrator.Tools.read_members(session_uri)

      {:ok, %{caps: caps}} = Ezagent.Kind.get_slice(builder_uri, :identity)

      assert {:error, :unauthorized} =
               Ezagent.Orchestrator.Tools.preflight_within_session_cap(caps, session_uri)

      # Idempotent: re-instantiating the same app reports not-fresh.
      assert {:ok, [^session_uri], %{fresh?: false}} =
               HelloSession.instantiate("session.hello", tmpl, workspace_uri)
    end

    test "rejects an invalid template" do
      workspace_uri = Ezagent.URI.workspace("hello-tmpl-bad")

      assert {:error, {:wrong_class, _}} =
               HelloSession.instantiate(
                 "session.hello",
                 %{"class" => "x", "session_name" => "y"},
                 workspace_uri
               )

      assert {:error, {:invalid_template, _}} =
               HelloSession.instantiate("session.hello", %{}, workspace_uri)
    end
  end
end
