defmodule Ezagent.Session.Config.ManifestImportTest do
  use ExUnit.Case, async: true

  alias Ezagent.Session.Config.ManifestImport

  test "reads only regular files beneath the configured root" do
    root = tmp_root("inside")
    path = Path.join(root, "member.yaml")
    File.mkdir_p!(root)
    File.write!(path, "name: worker\n")

    assert ManifestImport.read(path, root) == {:ok, "name: worker\n"}
  end

  test "rejects traversal outside the configured root before reading" do
    root = tmp_root("outside")
    File.mkdir_p!(root)

    assert ManifestImport.read("../secret.yaml", root) ==
             {:error, {:participant_manifest_read_failed, :manifest_path_outside_root}}
  end

  test "rejects symlink components that escape the configured root" do
    root = tmp_root("symlink")
    outside = tmp_root("symlink-target")
    File.mkdir_p!(root)
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "secret.yaml"), "name: secret\n")
    :ok = File.ln_s(outside, Path.join(root, "escape"))

    assert ManifestImport.read(Path.join(root, "escape/secret.yaml"), root) ==
             {:error, {:participant_manifest_read_failed, :manifest_symlink_forbidden}}
  end

  defp tmp_root(label) do
    Path.join(
      System.tmp_dir!(),
      "session-config-manifest-#{label}-#{System.unique_integer([:positive])}"
    )
  end
end
