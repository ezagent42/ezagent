defmodule Ezagent.Socialware.PublicViewTest do
  @moduledoc """
  P4 anonymous web access gate.

  The old SessionTemplate boolean is split into a per-session install relation
  plus the installed socialware definition's `visibility_policy.web_anon_access`.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.ActionSet.Session.ConfigActions
  alias Ezagent.Entity.{Session, SessionTemplate}
  alias Ezagent.Socialware.{DefinitionRegistry, Installation, PublicView}

  defp session_uri do
    Ezagent.URI.session(:team_alpha, :default, "pv-#{System.unique_integer([:positive])}")
  end

  defp public_session(web_anon_access) do
    u = System.unique_integer([:positive])
    name = "pv-def-#{u}"

    {:ok, _} =
      DefinitionRegistry.seed_definition_if_absent(definition(name, web_anon_access),
        workspace_uri: Ezagent.URI.workspace(:system)
      )

    content = %{name: "pv-tmpl-#{u}", installs: [name]}

    {:ok, template_uri} =
      SessionTemplate.persist_version_as_system(content, "system")

    uri = Ezagent.URI.session(:system, :default, "pv-#{System.unique_integer([:positive])}")

    {:ok, behaviors} =
      Installation.behavior_set_for_template(content, Ezagent.URI.workspace(:system))

    {:ok, _pid} =
      Ezagent.Socialware.TestCapHelper.spawn_session(%{uri: uri, behaviors: behaviors})

    :ok = Ezagent.WorkspaceRegistry.bind(uri, Ezagent.Capability.workspace_of(uri))

    :ok =
      Installation.install_template_installs(
        uri,
        Ezagent.URI.workspace(:system),
        content,
        Ezagent.Entity.User.admin_uri()
      )

    {:ok, _} = ConfigActions.system_set_working_copy(uri, %{session_template_uri: template_uri})
    uri
  end

  defp definition(name, web_anon_access) do
    %{
      name: name,
      bases: [Ezagent.ActionSet.Session, Ezagent.ActionSet.Publisher.SessionImpl],
      shape: [Ezagent.ActionSet.Turn, Ezagent.ActionSet.Surface],
      owner_policy: %{type: :installer},
      visibility_policy: %{publish_policy: :auto, web_anon_access: web_anon_access}
    }
  end

  describe "web_anon_access?/1 — fail-closed default" do
    test "a session with no install relation is NOT publicly viewable" do
      refute PublicView.web_anon_access?(session_uri())
    end

    test "a non-session URI is NOT publicly viewable" do
      refute PublicView.web_anon_access?(Ezagent.URI.entity(:team_alpha, :user, "alice"))
      refute PublicView.web_anon_access?(nil)
    end
  end

  describe "web_anon_access?/1 — install definition resolution" do
    test "true iff an installed socialware definition enables web anonymous access" do
      assert PublicView.web_anon_access?(public_session(true))
      refute PublicView.web_anon_access?(public_session(false))
    end
  end
end
