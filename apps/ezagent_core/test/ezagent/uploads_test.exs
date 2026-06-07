defmodule Ezagent.UploadsTest do
  use ExUnit.Case, async: false

  alias Ezagent.Uploads
  alias Ezagent.UriQuery

  setup do
    home =
      Path.join(
        System.tmp_dir!(),
        "ezagent_uploads_core_test_#{System.unique_integer([:positive])}"
      )

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

  test "registers a UriQuery resolver for upload resource paths", %{home: home} do
    :ok = Uploads.register()

    uri = Uploads.resource_uri("team-alpha", "stored.txt")
    expected = Path.join([home, Ezagent.Home.profile(), "uploads", "stored.txt"])

    assert {:ok, ^expected} = UriQuery.resolve(Uploads.attr(), uri)
    assert Uploads.path!(uri) == expected
  end

  test "filename path resolution keeps only the basename", %{home: home} do
    expected = Path.join([home, Ezagent.Home.profile(), "uploads", "secret.txt"])

    assert Uploads.path!("../secret.txt") == expected
  end

  test "store! copies the temp file and returns an upload resource URI", %{home: home} do
    :ok = Uploads.ensure_dir!()
    tmp = Path.join(home, "tmp-upload")
    File.write!(tmp, "payload")

    uri = Uploads.store!("team-alpha", "stored.txt", tmp)

    assert URI.to_string(uri) == "resource://team-alpha/uploads/stored.txt"

    assert File.read!(Path.join([home, Ezagent.Home.profile(), "uploads", "stored.txt"])) ==
             "payload"
  end

  test "non-upload resource URIs fail loudly at the call boundary" do
    uri = Ezagent.URI.resource("team-alpha", :avatar, "stored.txt")

    assert_raise ArgumentError, ~r/not an upload resource/, fn ->
      Uploads.path!(uri)
    end
  end
end
