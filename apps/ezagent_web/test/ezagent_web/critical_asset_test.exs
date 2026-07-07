defmodule EzagentWeb.CriticalAssetTest do
  use ExUnit.Case, async: true

  @critical_html_paths [
    "lib/ezagent_web/components/layouts/root.html.heex",
    "lib/ezagent_web/auth_boundary_layout.ex",
    "lib/ezagent_web/controllers/error_html/404.html.heex",
    "lib/ezagent_web/controllers/error_html/500.html.heex",
    "lib/ezagent_web/controllers/workspace_switch_html/denied.html.heex",
    "lib/ezagent_web/controllers/socialware/chat_feed_controller.ex",
    "lib/ezagent_web/controllers/socialware/external_feed_controller.ex"
  ]

  @forbidden_hosts [
    "fonts.googleapis.com",
    "fonts.gstatic.com",
    "cdn.jsdelivr.net/npm/xterm"
  ]

  @local_font_assets [
    "assets/css/local_fonts.css",
    "assets/static/fonts/inter-latin-400-normal.woff2",
    "assets/static/fonts/inter-latin-500-normal.woff2",
    "assets/static/fonts/inter-latin-600-normal.woff2",
    "assets/static/fonts/inter-latin-700-normal.woff2",
    "assets/static/fonts/inter-latin-800-normal.woff2",
    "assets/static/fonts/space-mono-latin-400-normal.woff2",
    "assets/static/fonts/space-mono-latin-700-normal.woff2",
    "assets/static/fonts/LICENSE-inter.txt",
    "assets/static/fonts/LICENSE-space-mono.txt"
  ]

  test "critical HTML shells do not block on third-party font or xterm hosts" do
    offenders =
      for path <- @critical_html_paths,
          source = File.read!(path),
          host <- @forbidden_hosts,
          String.contains?(source, host),
          do: "#{path}: #{host}"

    assert offenders == []
  end

  test "local font assets are available to the asset pipeline" do
    missing =
      @local_font_assets
      |> Enum.reject(&File.exists?/1)

    assert missing == []
  end
end
