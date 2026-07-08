defmodule Ezagent.Home.SocialwareSeedTest do
  use ExUnit.Case, async: true

  alias Ezagent.Home.SocialwareSeed

  defp tmp_dir(tag) do
    dir = Path.join(System.tmp_dir!(), "sw-seed-#{tag}-#{System.unique_integer([:positive])}")
    File.rm_rf!(dir)
    dir
  end

  defp write!(path, body) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
  end

  describe "seed!/1" do
    test "copies each <name> package dir from source into dest" do
      source = tmp_dir("src")
      dest = tmp_dir("dest")
      write!(Path.join(source, "autoservice/manifest.yaml"), "name: autoservice-tier1\n")
      write!(Path.join(source, "autoservice/kb/corpus.md"), "corpus\n")
      write!(Path.join(source, "kanban/manifest.yaml"), "name: kanban\n")

      assert :ok = SocialwareSeed.seed!(source: source, dest: dest)

      assert File.read!(Path.join(dest, "autoservice/manifest.yaml")) ==
               "name: autoservice-tier1\n"

      assert File.read!(Path.join(dest, "autoservice/kb/corpus.md")) == "corpus\n"
      assert File.read!(Path.join(dest, "kanban/manifest.yaml")) == "name: kanban\n"
    end

    test "is idempotent — a pre-existing package dir is NOT overwritten (respects operator edits)" do
      source = tmp_dir("src")
      dest = tmp_dir("dest")
      write!(Path.join(source, "autoservice/manifest.yaml"), "name: shipped\n")
      # operator hand-edited the deployed copy
      write!(Path.join(dest, "autoservice/manifest.yaml"), "name: operator-edited\n")

      assert :ok = SocialwareSeed.seed!(source: source, dest: dest)

      assert File.read!(Path.join(dest, "autoservice/manifest.yaml")) == "name: operator-edited\n"
    end

    test "a missing source dir is a silent no-op" do
      dest = tmp_dir("dest")
      missing = tmp_dir("missing-src")
      refute File.dir?(missing)

      assert :ok = SocialwareSeed.seed!(source: missing, dest: dest)
      refute File.dir?(dest) and File.ls!(dest) != []
    end

    test "only directory children are seeded (stray files ignored)" do
      source = tmp_dir("src")
      dest = tmp_dir("dest")
      write!(Path.join(source, "README.md"), "not a package\n")
      write!(Path.join(source, "autoservice/manifest.yaml"), "name: autoservice-tier1\n")

      assert :ok = SocialwareSeed.seed!(source: source, dest: dest)

      assert File.dir?(Path.join(dest, "autoservice"))
      refute File.exists?(Path.join(dest, "README.md"))
    end
  end

  describe "source_dirs/0" do
    test "enumerates loaded apps' priv/socialware_seed (incl. ezagent_web, the shipped source)" do
      dirs = SocialwareSeed.source_dirs()
      assert is_list(dirs)

      assert Enum.any?(dirs, fn d ->
               String.ends_with?(d, Path.join("priv", "socialware_seed")) and d =~ "ezagent_web"
             end)
    end
  end
end
