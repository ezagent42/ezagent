defmodule EzagentPluginLiveview.SessionViewRegistryIntegrationTest do
  @moduledoc """
  P2 — end-to-end contract with the REAL registered views, in the one app that
  may legally depend on BOTH the registry (ezagent_domain_ui) and the concrete
  views (PageView in ezagent_domain_socialware; ConversationView here). Spawns a
  real socialware-subset `Entity.Session` so PageView.applies_to?/1 is true and
  the registry's external_renderers/1 discovery — the exact registration point
  the P3 ExternalAdapter will consult — is actually exercised.
  """
  # Spawns a real socialware-subset `Entity.Session` (touches KindSnapshot/Repo).
  use EzagentCore.DataCase, async: false

  alias Ezagent.Ecto.KindSnapshot
  alias Ezagent.Entity.Session
  alias Ezagent.UI.SessionViewRegistry
  alias EzagentDomainSocialware.PageView
  alias EzagentPluginLiveview.Views.ConversationView

  setup do
    SessionViewRegistry.init()
    :ok
  end

  # Spawn a real socialware session. Surface.create/1 seeds a `:surface` map on
  # spawn, so PageView.applies_to?/1 (which checks for the slice) returns true.
  defp spawn_socialware_session do
    uri =
      Ezagent.URI.session(
        :team_alpha,
        :socialware,
        "view-contract-#{System.unique_integer([:positive])}"
      )

    :ok = KindSnapshot.delete(URI.to_string(uri))

    {:ok, _pid} =
      Ezagent.Kind.spawn(Session, %{
        uri: uri,
        behaviors: Session.socialware_behaviors()
      })

    :ok = Ezagent.WorkspaceRegistry.bind(uri, Ezagent.Capability.workspace_of(uri))
    uri
  end

  describe "P2 contract — real views" do
    test "PageView is an external renderer; ConversationView is internal-only" do
      assert SessionViewRegistry.external_render?(PageView) == true
      assert SessionViewRegistry.external_render?(ConversationView) == false
    end

    test "external_renderers/1 discovers PageView (excludes ConversationView) on a real session" do
      :ok = SessionViewRegistry.register(ConversationView)
      :ok = SessionViewRegistry.register(PageView)

      uri = spawn_socialware_session()

      # The P3 registration point: PageView is discovered as an external
      # renderer for this session; ConversationView (internal-only) is NOT.
      external_ids = Enum.map(SessionViewRegistry.external_renderers(uri), & &1.id)
      assert :page in external_ids
      refute :conversation in external_ids

      # The internal switcher is unchanged: BOTH still appear in applicable_views.
      internal_ids = Enum.map(SessionViewRegistry.applicable_views(uri), & &1.id)
      assert :page in internal_ids
      assert :conversation in internal_ids
    end
  end
end
