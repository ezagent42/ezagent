defmodule EzagentPluginPkgTest.Builder do
  @moduledoc false
  # Builds a plugin PACKAGE directory (manifest.json + ebin/ + priv/) for
  # the plugin-package E2E gate. The plugin modules are compiled under
  # test/support; this helper copies their beams into the package ebin
  # (via :code.get_object_code/1), writes the .app file, the manifest, a
  # tiny island asset, and a seed recipe. The result is a real package a
  # developer could `mix ezagent.plugin.install` — exercised end-to-end
  # through Ezagent.PluginPackage.install/1.

  alias Ezagent.PluginPackage.Manifest

  @slug "pkg-test"

  @doc "Build a v1 or v2 package directory under `tmp_dir`. Returns the dir path."
  def build!(version, tmp_dir) when version in [:v1, :v2] do
    {plugin_mod, app_mod, behavior_mod, pkg_version, manifest_version, recipe_name} =
      case version do
        :v1 ->
          {EzagentPluginPkgTest, EzagentPluginPkgTest.Application, EzagentPluginPkgTest.EchoBehavior,
           "0.1.0", "v1", "pkg-echo-recipe"}

        :v2 ->
          {EzagentPluginPkgTestV2, EzagentPluginPkgTestV2.Application,
           EzagentPluginPkgTestV2.EchoBehavior, "0.2.0", "v2", "pkg-echo-recipe"}
      end

    dir = Path.join(tmp_dir, "#{@slug}-#{manifest_version}")
    File.rm_rf!(dir)
    ebin = Path.join(dir, "ebin")
    priv = Path.join(dir, "priv")
    File.mkdir_p!(ebin)
    File.mkdir_p!(Path.join(priv, "static/assets"))
    File.mkdir_p!(Path.join(priv, "seed"))

    write_beams!(ebin, [plugin_mod, app_mod, behavior_mod])
    write_app_file!(ebin, plugin_mod, app_mod, [plugin_mod, app_mod, behavior_mod])
    write_island_asset!(priv, manifest_version)
    write_seed_recipe!(priv, recipe_name)
    write_manifest!(dir, plugin_mod, app_mod, behavior_mod, pkg_version, manifest_version, recipe_name)

    dir
  end

  defp write_beams!(ebin, modules) do
    Enum.each(modules, fn mod ->
      case :code.get_object_code(mod) do
        {^mod, beam_binary, _file} ->
          File.write!(Path.join(ebin, "#{mod}.beam"), beam_binary)

        _ ->
          raise "could not get object code for #{inspect(mod)} — is it compiled?"
      end
    end)
  end

  defp write_app_file!(ebin, _plugin_mod, app_mod, modules) do
    app_name = "ezagent_pkg_test"
    mod_str = "{#{format_atom(app_mod)},[]}"
    modules_str = "[#{Enum.map_join(modules, ",", &format_atom/1)}]"

    contents = """
    {application,#{app_name},
        [{description,"plugin-package E2E fixture"},
         {mod,#{mod_str}},
         {modules,#{modules_str}},
         {registered,[]},
         {applications,[kernel,stdlib,ezagent_core,ezagent_domain_agent]}]}.
    """

    File.write!(Path.join(ebin, "#{app_name}.app"), contents)
  end

  # Format an Elixir module atom for an Erlang .app term file. Erlang
  # atoms containing `.` / uppercase must be single-quoted; the actual
  # compiled module atom is `Elixir.<...>` (Atom.to_string/1), which we
  # quote so `:application.load/1` reads the SAME atom the .beam defines.
  defp format_atom(mod) do
    s = Atom.to_string(mod)

    if Regex.match?(~r/^[a-z][a-z0-9_]*$/, s) do
      s
    else
      "'#{s}'"
    end
  end

  defp write_island_asset!(priv, version) do
    File.write!(
      Path.join(priv, "static/assets/main.js"),
      "// plugin-package E2E island bundle #{version}\nexport const version = \"#{version}\";\n"
    )
  end

  defp write_seed_recipe!(priv, recipe_name) do
    recipe = %{
      "name" => recipe_name,
      "behaviors" => [],
      "requested_caps" => []
    }

    File.write!(Path.join(priv, "seed/recipe.json"), Jason.encode!(recipe))
  end

  defp write_manifest!(dir, plugin_mod, _app_mod, behavior_mod, pkg_version, _manifest_version, recipe_name) do
    manifest = %Manifest{
      slug: @slug,
      version: pkg_version,
      app: :ezagent_pkg_test,
      plugin_module: plugin_mod,
      behaviors: [{Ezagent.Entity.Agent, :echo_pkg, behavior_mod}],
      template_classes: [],
      routing_tables: [],
      asset_entries: [
        %{route: "main.js", file: "static/assets/main.js", content_type: "text/javascript"}
      ],
      seed_refs: [%{kind: :recipe, name: recipe_name, file: "seed/recipe.json"}],
      config_schema: nil
    }

    File.write!(Path.join(dir, "manifest.json"), Jason.encode!(Manifest.to_json(manifest), pretty: true))
  end
end
