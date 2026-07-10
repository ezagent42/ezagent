defmodule Ezagent.World.SlotMountGateTest do
  @moduledoc """
  Layer-2 of the two-layer typed-slot gate (handoff §3.2): the authoritative,
  CI hard-fail static check that world surfaces only mount through the
  registry-backed renderer. The developer-facing mirror is
  `assets/scripts/check-mounts.mjs` (`pnpm check:mounts`) — keep the two in
  lockstep. Layer-1 (route slots ⊆ registry + manifest drift) lives in
  `slot_registry_test.exs`.
  """
  use ExUnit.Case, async: true

  alias Ezagent.World.SlotRegistry

  @src Path.expand("../../../assets/src", __DIR__)
  @main Path.join(@src, "main.tsx")
  @components Path.join(@src, "components")

  # Layout-slot Surface components: the renderer's leaves, mountable ONLY by the
  # renderer in main.tsx.
  @surfaces ~w(LayoutEditor SessionsTable Conversation PtyTerminalSurface
               AdminSurface WorkspacePluginSurface IdentitiesSurface)

  # Sanctioned `:subcomponent` mounts (parent-owned, data-world-subcomponent).
  @subcomponent_allowlist %{"Conversation.tsx" => ["PtyTerminalSurface"]}

  defp component_files do
    @components |> File.ls!() |> Enum.filter(&String.ends_with?(&1, ".tsx"))
  end

  test "Check 1 — single mount point: createRoot only in main.tsx" do
    offenders =
      for file <- component_files(),
          Regex.match?(~r/\bcreateRoot\s*\(/, File.read!(Path.join(@components, file))),
          do: file

    assert offenders == [],
           "surfaces must mount via main.tsx's renderer, not their own React root: #{inspect(offenders)}"
  end

  test "Check 2 — no surface bypass outside the renderer (subcomponents allowlisted + marked)" do
    violations =
      for file <- component_files(), reduce: [] do
        acc ->
          src = File.read!(Path.join(@components, file))
          allowed = Map.get(@subcomponent_allowlist, file, [])

          bypass =
            for surface <- @surfaces,
                Regex.match?(~r/import[^\n]*\b#{surface}\b[^\n]*from/, src),
                surface not in allowed,
                do: "#{file} imports #{surface} outside the renderer"

          marker =
            if allowed != [] and not String.contains?(src, "data-world-subcomponent"),
              do: [
                "#{file} declares a subcomponent but renders no data-world-subcomponent marker"
              ],
              else: []

          acc ++ bypass ++ marker
      end

    assert violations == [], Enum.join(violations, "\n")
  end

  test "Check 3 — family parity: renderer handles exactly the manifest's families" do
    switch_body = renderer_switch_body()

    switch_cases =
      ~r/case "([a-z_]+)":/
      |> Regex.scan(switch_body, capture: :all_but_first)
      |> List.flatten()
      |> MapSet.new()

    # 插件页面 family 经 PLUGIN_PAGE_RENDERERS 注册表 map（default 分支查 key）
    # 渲染，不再是字面 switch case（PluginPageRegistry 重构，2026-07-09）——
    # map 的 key 与 switch case 并集才是 renderer 处理的 family 全集。
    plugin_page_keys = plugin_page_renderer_keys()

    # 撞名 = switch 分支静默遮蔽注册表条目（对应 SlotRegistry 的编译期防呆）
    assert MapSet.disjoint?(switch_cases, plugin_page_keys),
           "plugin page keys shadowed by literal switch cases: " <>
             "#{inspect(MapSet.intersection(switch_cases, plugin_page_keys) |> MapSet.to_list())}"

    renderer_cases = MapSet.union(switch_cases, plugin_page_keys)
    manifest_families = SlotRegistry.manifest()["renderer_families"] |> Map.keys() |> MapSet.new()

    assert renderer_cases == manifest_families,
           "renderer families #{inspect(MapSet.to_list(renderer_cases))} != manifest families " <>
             "#{inspect(MapSet.to_list(manifest_families))}"
  end

  test "Check 4 — no unknown fallback: renderer throws on unregistered type / unhandled family" do
    main = File.read!(@main)
    switch_body = renderer_switch_body()

    assert Regex.match?(~r/if \(!spec\) \{[\s\S]*?throw/, main),
           "rendererFamily must throw on an unregistered slot type (no silent fallback)"

    default_branch = switch_body |> String.split("default:") |> List.last()

    assert String.contains?(default_branch, "throw"),
           "renderLayoutComponent default branch must throw (no silent fallback)"

    refute String.contains?(default_branch, "Surface"),
           "renderLayoutComponent default branch must not render a surface — unknown family = throw"
  end

  # `const PLUGIN_PAGE_RENDERERS = { kanban: (component, context) => ... }` 的
  # key 集合——服务端 PluginPageRegistry 的前端对应面（显式 import，Vite 静态打包）。
  defp plugin_page_renderer_keys do
    main = File.read!(@main)

    case :binary.match(main, "const PLUGIN_PAGE_RENDERERS") do
      {s, _} ->
        rest = binary_part(main, s, byte_size(main) - s)

        block =
          case :binary.match(rest, "\nfunction ") do
            {e, _} -> binary_part(rest, 0, e)
            :nomatch -> rest
          end

        ~r/^  ([a-z_]+): \(/m
        |> Regex.scan(block, capture: :all_but_first)
        |> List.flatten()
        |> MapSet.new()

      :nomatch ->
        MapSet.new()
    end
  end

  defp renderer_switch_body do
    main = File.read!(@main)
    start = :binary.match(main, "switch (rendererFamily(component.type))")

    case start do
      {s, _} ->
        rest = binary_part(main, s, byte_size(main) - s)

        case :binary.match(rest, "\nfunction ") do
          {e, _} -> binary_part(rest, 0, e)
          :nomatch -> rest
        end

      :nomatch ->
        flunk("could not locate renderLayoutComponent switch in main.tsx")
    end
  end
end
