defmodule EzagentPluginLiveview.PluginsLiveTest do
  @moduledoc """
  `/plugins` is 100% registry-driven (plugin authoring contract SPEC
  §6.2 / PR-4). These tests assert the page renders one card per plugin
  registered in `Ezagent.PluginRegistry`, and that each card's config
  icon is wired from the plugin's own `config_surface/0`:

    - a `:route`-surface plugin (feishu) → config link to its `path`.
    - a `:flavor`-surface plugin (cc) → config link to the
      flavor-filtered identities view.

  No per-slug knowledge lives in `plugins_live` anymore — the deleted
  hardcoded `pretty_name`/`pretty_desc`/`primary_link` are what these
  tests replace.
  """
  use ExUnit.Case

  # #52 Mode-A: cross-tier LiveView suite — mounts views that resolve
  # sibling-app domain modules; runs only in the umbrella. Excluded
  # standalone (`cd apps/ezagent_plugin_liveview && mix test`).
  @moduletag :umbrella_only
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint EzagentWeb.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(EzagentCore.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, {:shared, self()})

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{
        "current_entity_uri" => URI.to_string(Ezagent.Entity.User.admin_uri())
      })

    {:ok, conn: conn}
  end

  test "renders the page header", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/plugins")
    assert html =~ "Plugins"
    assert html =~ "Installed ezagent plugins"
  end

  test "renders one card per plugin registered in PluginRegistry", %{conn: conn} do
    {:ok, _lv, html} = live(conn, "/plugins")

    registered = Ezagent.PluginRegistry.list_all()
    # All 5 plugin apps are umbrella deps of ezagent_web — each
    # self-registers via Ezagent.Plugin.boot/1 at app start.
    assert length(registered) >= 1

    # Every registered plugin's declared name appears as a card.
    for plugin_module <- registered do
      info = plugin_module.plugin_info()
      assert html =~ info.name, "expected a card for plugin #{info.slug} (#{info.name})"
      assert html =~ "v#{info.version}"
    end
  end

  test "a :route-surface plugin (feishu) shows a config link to its path", %{conn: conn} do
    # Feishu declares config_surface/0 → %{kind: :route, path: ...}.
    assert %{kind: :route, path: path} =
             EzagentPluginFeishu.Application.config_surface()

    assert path == "/plugins/feishu/bindings"

    {:ok, _lv, html} = live(conn, "/plugins")
    assert html =~ ~s(href="#{path}")
  end

  test "a :flavor-surface plugin (cc) shows the flavor-filtered config link", %{conn: conn} do
    # cc declares config_surface/0 → %{kind: :flavor, flavor: "cc"}.
    assert %{kind: :flavor, flavor: flavor} =
             EzagentPluginCc.Application.config_surface()

    assert flavor == "cc"

    {:ok, _lv, html} = live(conn, "/plugins")
    # :flavor surface → /identities?filter=agent:<flavor> (SPEC §6.1).
    assert html =~ ~s(href="/identities?filter=agent:#{flavor}")
  end

  test "page no longer carries per-slug hardcoded metadata functions" do
    # The contract: plugins_live exports no pretty_name/pretty_desc/
    # primary_link — /plugins is registry-driven.
    exports = EzagentPluginLiveview.PluginsLive.__info__(:functions)
    refute Keyword.has_key?(exports, :pretty_name)
    refute Keyword.has_key?(exports, :pretty_desc)
    refute Keyword.has_key?(exports, :primary_link)
  end
end
