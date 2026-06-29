defmodule Ezagent.PluginPackage.ManifestSecurityTest do
  @moduledoc """
  Security regression tests for the plugin-package manifest (H-1 path
  traversal, L-9 atom-table-exhaustion guard, H-2 no silent no-op).
  """

  use ExUnit.Case, async: true

  alias Ezagent.PluginPackage.Manifest

  describe "H-1: asset_entries[].file path-traversal rejection at validate" do
    test "a relative file under priv/ is accepted" do
      manifest =
        manifest(%{
          "asset_entries" => [
            %{"route" => "main.js", "file" => "static/assets/main.js"}
          ]
        })

      assert [%{file: "static/assets/main.js"}] = manifest.asset_entries
    end

    test "a file with a `..` segment is REJECTED" do
      assert_raise ArgumentError, ~r/path-traversal defense/, fn ->
        manifest(%{
          "asset_entries" => [
            %{"route" => "evil", "file" => "../../../.claude/auth.json"}
          ]
        })
      end
    end

    test "an absolute file path is REJECTED" do
      assert_raise ArgumentError, ~r/RELATIVE path/, fn ->
        manifest(%{
          "asset_entries" => [%{"route" => "evil", "file" => "/etc/passwd"}]
        })
      end
    end

    test "a seed_ref file with a `..` segment is REJECTED" do
      assert_raise ArgumentError, ~r/path-traversal defense/, fn ->
        manifest(%{
          "seed_refs" => [
            %{"kind" => "recipe", "name" => "x", "file" => "../evil.json"}
          ]
        })
      end
    end
  end

  describe "H-1: PluginAssetRegistry.register defense-in-depth" do
    alias Ezagent.PluginAssetRegistry

    test "a manifest whose asset file escapes priv_dir (bypassing validate) raises at register" do
      # Construct a Manifest struct directly with a `..` file (parse!/1 would
      # reject it; this simulates a future caller that bypasses the manifest
      # parser) and assert register/2's own path-escape guard fires.
      priv = Path.join(System.tmp_dir!(), "pkg-sec-#{System.unique_integer([:positive])}")

      manifest = %Manifest{
        slug: "evil",
        version: "0.1.0",
        app: :evil_pkg,
        plugin_module: EzagentPluginPkgTest,
        behaviors: [],
        template_classes: [],
        routing_tables: [],
        asset_entries: [%{route: "evil", file: "../../etc/passwd", content_type: "text/plain"}],
        seed_refs: [],
        config_schema: nil
      }

      assert_raise ArgumentError, ~r/OUTSIDE priv_dir.*path-traversal/, fn ->
        PluginAssetRegistry.register(manifest, priv)
      end
    end
  end

  describe "L-9: atom-table-exhaustion guards" do
    test "an action with non-snake-case chars is REJECTED" do
      assert_raise ArgumentError, ~r/lowercase action atom/, fn ->
        manifest(%{
          "behaviors" => [
            %{"kind" => "Ezagent.Entity.Agent", "action" => "Evil Action!", "behavior" => "Ezagent.X"}
          ]
        })
      end
    end

    test "an action with a trailing `?` (predicate) is accepted" do
      manifest =
        manifest(%{
          "behaviors" => [
            %{"kind" => "Ezagent.Entity.Agent", "action" => "has_cap?", "behavior" => "Ezagent.X"}
          ]
        })

      assert [{_, :has_cap?, _} | _] = manifest.behaviors
    end

    test "an app with uppercase chars is REJECTED" do
      assert_raise ArgumentError, ~r/snake_case atom/, fn ->
        manifest(%{"app" => "EvilApp"})
      end
    end
  end

  describe "H-2: seed_ref.kind is :recipe only (no silent no-op)" do
    test "a :socialware seed_ref is REJECTED at parse (not silently dropped)" do
      assert_raise ArgumentError, ~r/kind must be "recipe"/, fn ->
        manifest(%{
          "seed_refs" => [
            %{"kind" => "socialware", "name" => "x", "file" => "seed/soc.json"}
          ]
        })
      end
    end
  end

  defp manifest(overrides) do
    base = %{
      "slug" => "test-pkg",
      "version" => "0.1.0",
      "app" => "test_pkg",
      "plugin_module" => "EzagentPluginPkgTest",
      "behaviors" => [],
      "asset_entries" => [],
      "seed_refs" => []
    }

    Manifest.parse!(Map.merge(base, overrides))
  end
end
