defmodule Ezagent.Socialware.ShippedManifestTest do
  @moduledoc """
  Unit gate for `Ezagent.Socialware.ShippedManifest` — the shared thin loader
  the demo test-fixture modules (`Ezagent.Socialware.Demo.Hello`,
  `EzagentPluginKanban.Demo`) delegate to instead of each carrying the same
  discover→read→parse→override boilerplate.

  The real shipped packages live in `ezagent_web`'s priv (not a dep here), so
  these tests exercise the loader against a temp seed source dir via the
  tests-only `:source_dirs` seam (mirroring
  `Ezagent.Home.SocialwareSeed.seed!/1`'s `:source` seam). The per-package
  drift gates against the REAL shipped YAMLs stay where the files are loaded
  (`ezagent_web` / `ezagent_plugin_kanban`).
  """
  use ExUnit.Case, async: true

  alias Ezagent.Socialware.ShippedManifest

  @relpath "demo-fixture/manifest.yaml"

  @manifest """
  name: demo-fixture
  version: 0.1.0
  title: Fixture socialware
  roles:
    - role_name: helper
      fill: agent
      recipe: np
      flavor: py
    - role_name: owner
      fill: user
  """

  setup do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "shipped-manifest-#{System.unique_integer([:positive])}"
      )

    pkg_dir = Path.join(tmp, "demo-fixture")
    File.mkdir_p!(pkg_dir)
    File.write!(Path.join(pkg_dir, "manifest.yaml"), @manifest)
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, source: tmp}
  end

  describe "path/2" do
    test "finds the shipped manifest across the seed source dirs", %{source: source} do
      empty = Path.join(source, "empty-source")
      File.mkdir_p!(empty)

      assert ShippedManifest.path(@relpath, source_dirs: [empty, source]) ==
               Path.join(source, @relpath)
    end

    test "nil when no source dir carries the package", %{source: source} do
      assert ShippedManifest.path("no-such-pkg/manifest.yaml", source_dirs: [source]) == nil
    end

    test "defaults to SocialwareSeed.source_dirs/0 (no shipping app loaded here)" do
      # domain_session does not dep the shipping app (ezagent_web), so the
      # default enumeration finds nothing — the nil contract, not a crash.
      assert ShippedManifest.path(
               "no-such-pkg-#{System.unique_integer([:positive])}/manifest.yaml"
             ) == nil
    end
  end

  describe "load!/2" do
    test "returns the parsed YAML verbatim with no overrides", %{source: source} do
      attrs = ShippedManifest.load!(@relpath, source_dirs: [source])

      assert attrs["name"] == "demo-fixture"
      assert attrs["version"] == "0.1.0"
      assert attrs["title"] == "Fixture socialware"

      assert attrs["roles"] == [
               %{"role_name" => "helper", "fill" => "agent", "recipe" => "np", "flavor" => "py"},
               %{"role_name" => "owner", "fill" => "user"}
             ]
    end

    test ":name overrides the definition name, nothing else", %{source: source} do
      attrs = ShippedManifest.load!(@relpath, name: "demo-run-1", source_dirs: [source])

      assert attrs["name"] == "demo-run-1"
      assert attrs["version"] == "0.1.0"
    end

    test ":flavor overrides EVERY agent role-slot, non-agent slots untouched", %{source: source} do
      attrs = ShippedManifest.load!(@relpath, flavor: "bare-stub", source_dirs: [source])

      assert [agent, user] = attrs["roles"]
      assert agent["flavor"] == "bare-stub"
      assert agent["recipe"] == "np"
      refute Map.has_key?(user, "flavor")
    end

    test "fail-loud: missing manifest raises with the package name", %{source: source} do
      assert_raise RuntimeError,
                   ~r/no-such-pkg manifest\.yaml not found in any loaded app's priv\/socialware_seed/,
                   fn ->
                     ShippedManifest.load!("no-such-pkg/manifest.yaml", source_dirs: [source])
                   end
    end

    test "fail-loud: unparseable manifest raises, never empty attrs", %{source: source} do
      pkg_dir = Path.join(source, "broken")
      File.mkdir_p!(pkg_dir)
      File.write!(Path.join(pkg_dir, "manifest.yaml"), "- not\n- a\n- map\n")

      assert_raise RuntimeError, ~r/broken manifest\.yaml failed to parse/, fn ->
        ShippedManifest.load!("broken/manifest.yaml", source_dirs: [source])
      end
    end

    test "fail-loud: unknown option raises", %{source: source} do
      assert_raise ArgumentError, fn ->
        ShippedManifest.load!(@relpath, role_name: "nope", source_dirs: [source])
      end
    end
  end
end
