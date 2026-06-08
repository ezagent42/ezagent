defmodule Ezagent.UploadsTest do
  @moduledoc """
  Resource-unification P2b — uploads store + read through the hardened
  `Ezagent.Resource.FsResolver`, workspace-partitioned.

  Pins the new ws-partitioned layout (`…/uploads/<ws>/<name>`), the
  authorization-bearing resolve (foreign-workspace denied), and the
  same-filename-two-workspaces isolation invariant.
  """
  use ExUnit.Case, async: false

  alias Ezagent.Uploads

  setup do
    home =
      Path.join(
        System.tmp_dir!(),
        "ezagent_uploads_core_test_#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(home)
    prior_home = System.get_env("EZAGENT_HOME")
    System.put_env("EZAGENT_HOME", home)

    on_exit(fn ->
      if prior_home do
        System.put_env("EZAGENT_HOME", prior_home)
      else
        System.delete_env("EZAGENT_HOME")
      end

      _ = File.rm_rf(home)
    end)

    %{home: home}
  end

  defp uploads_root(home), do: Path.join([home, Ezagent.Home.profile(), "uploads"])

  test "resolve/2 maps an uploads URI to …/uploads/<ws>/<name> under the caller scope",
       %{home: home} do
    uri = Uploads.resource_uri("team-alpha", "stored.txt")
    expected = Path.join([uploads_root(home), "team-alpha", "stored.txt"])

    assert {:ok, ^expected} = Uploads.resolve(uri, %{workspace: "team-alpha"})
    assert Uploads.path!(uri, %{workspace: "team-alpha"}) == expected
  end

  test "resolve/2 of a FOREIGN-workspace uploads URI is denied (authority/2)" do
    uri = Uploads.resource_uri("victim", "stored.txt")
    assert {:error, {:foreign_workspace, _}} = Uploads.resolve(uri, %{workspace: "team-alpha"})

    assert_raise ArgumentError, ~r/could not resolve upload path/, fn ->
      Uploads.path!(uri, %{workspace: "team-alpha"})
    end
  end

  test "store! copies into the ws-partitioned store and returns the resource URI",
       %{home: home} do
    tmp = Path.join(home, "tmp-upload")
    File.write!(tmp, "payload")

    uri = Uploads.store!("team-alpha", "stored.txt", tmp)
    assert URI.to_string(uri) == "resource://team-alpha/uploads/stored.txt"

    assert File.read!(Path.join([uploads_root(home), "team-alpha", "stored.txt"])) == "payload"
  end

  test "same filename in two workspaces is isolated on disk and on read", %{home: home} do
    tmp_a = Path.join(home, "tmp-a")
    tmp_b = Path.join(home, "tmp-b")
    File.write!(tmp_a, "acme-bytes")
    File.write!(tmp_b, "beta-bytes")

    uri_a = Uploads.store!("acme", "shared.pdf", tmp_a)
    uri_b = Uploads.store!("beta", "shared.pdf", tmp_b)

    path_a = Uploads.path!(uri_a, %{workspace: "acme"})
    path_b = Uploads.path!(uri_b, %{workspace: "beta"})

    refute path_a == path_b
    assert File.read!(path_a) == "acme-bytes"
    assert File.read!(path_b) == "beta-bytes"

    # acme's scope cannot read beta's URI (workspace isolation).
    assert {:error, {:foreign_workspace, _}} = Uploads.resolve(uri_b, %{workspace: "acme"})
  end

  test "a non-uploads resource URI is :none (not ours)" do
    uri = Ezagent.URI.resource("team-alpha", :avatar, "stored.txt")
    assert Uploads.resolve(uri, %{workspace: "team-alpha"}) == :none

    assert_raise ArgumentError, ~r/not an upload resource/, fn ->
      Uploads.path!(uri, %{workspace: "team-alpha"})
    end
  end

  test "a traversal name segment is rejected before any byte is written" do
    uri = Ezagent.URI.resource("team-alpha", "uploads", "..")

    assert {:error, {:unsafe_segment, _}} = Uploads.resolve(uri, %{workspace: "team-alpha"})
  end
end
