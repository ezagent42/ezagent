defmodule EzagentWeb.CommandRoutesTest do
  @moduledoc """
  V1 UI PR-2 (SPEC §2.2 Source 1) — `command_routes/0` projects the
  Phoenix Router into enriched nav routes for the CmdK palette.
  """

  use ExUnit.Case, async: true

  alias EzagentWeb.CommandRoutes

  describe "command_routes/0" do
    test "returns enriched maps with label/path/icon/group" do
      routes = CommandRoutes.command_routes()

      assert routes != []

      for route <- routes do
        assert %{label: label, path: path, icon: icon, group: group} = route
        assert is_binary(label) and label != ""
        assert is_binary(path) and String.starts_with?(path, "/")
        assert is_binary(icon) and icon != ""
        assert is_binary(group) and group != ""
      end
    end

    test "includes the L1 nav pages (/sessions, /identities, /plugins) + admin /admin/routing" do
      # 2026-05-25 — /routing relocated to /admin/routing (admin scope).
      # The workspace-tile triplet is now Sessions / Identities / Plugins;
      # Routing lives in the Admin group of the palette.
      paths = CommandRoutes.command_routes() |> Enum.map(& &1.path)

      for expected <- ["/sessions", "/identities", "/plugins", "/admin/routing"] do
        assert expected in paths, "expected #{expected} in command routes, got: #{inspect(paths)}"
      end

      refute "/routing" in paths,
             "stale /routing path leaked into palette catalog after 2026-05-25 relocation"
    end

    test "the /sessions route carries its curated label + group" do
      sessions = Enum.find(CommandRoutes.command_routes(), &(&1.path == "/sessions"))

      assert sessions.label == "Sessions"
      assert sessions.group == "Navigate"
    end

    test "excludes routes with path parameters (e.g. /identities/agents/:uri)" do
      paths = CommandRoutes.command_routes() |> Enum.map(& &1.path)

      refute Enum.any?(paths, &String.contains?(&1, ":")),
             "command routes must be parameter-free L1/L2 pages"
    end

    test "every returned path is a real live route in the router" do
      live_paths =
        EzagentWeb.Router.__routes__()
        |> Enum.filter(&(&1.verb == :get and &1.plug == Phoenix.LiveView.Plug))
        |> Enum.map(& &1.path)
        |> MapSet.new()

      for route <- CommandRoutes.command_routes() do
        assert route.path in live_paths,
               "#{route.path} is in the curated catalog but is not a live route"
      end
    end

    test "result paths are unique" do
      paths = CommandRoutes.command_routes() |> Enum.map(& &1.path)
      assert paths == Enum.uniq(paths)
    end
  end
end
