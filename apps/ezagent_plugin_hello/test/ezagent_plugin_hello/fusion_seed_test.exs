defmodule EzagentPluginHello.FusionSeedTest do
  use EzagentCore.DataCase, async: false

  alias Ezagent.Socialware.ExternalFeed
  alias EzagentPluginHello.FusionSeed

  setup do
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_agent)
    {:ok, _} = Application.ensure_all_started(:ezagent_plugin_curl_agent)
    {:ok, _} = Application.ensure_all_started(:ezagent_plugin_kanban)

    Enum.each(EzagentPluginHello.Application.roles(), fn recipe ->
      {:ok, _} = Ezagent.Agent.RecipeRegistry.seed_role_if_absent(recipe)
    end)

    :ok
  end

  test "reconstructs the committed Fusion page on an initially absent workspace and session" do
    workspace = "fusion-seed-#{System.unique_integer([:positive])}"
    session_uri = Ezagent.URI.session(workspace, :hello, "fusion")
    assert :error = Ezagent.KindRegistry.lookup(session_uri)

    assert {:ok, %{session_uri: ^session_uri, turn_id: turn_id}} =
             FusionSeed.run(workspace: workspace)

    assert is_binary(turn_id) and turn_id != ""

    expected_body = seed_path("body.json") |> File.read!() |> Jason.decode!()
    expected_css = seed_path("shell.css") |> File.read!()

    assert {:ok, snapshot} =
             ExternalFeed.snapshot(session_uri, Ezagent.Entity.User.admin_uri())

    assert snapshot.page == expected_body
    assert snapshot.shell_css == expected_css

    assert {:ok, %{session_uri: ^session_uri}} = FusionSeed.run(workspace: workspace)
  end

  test "fails explicitly when the full website body is missing" do
    workspace = "fusion-missing-body-#{System.unique_integer([:positive])}"

    assert {:error, {:seed_file, :body, :enoent}} =
             FusionSeed.run(workspace: workspace, body_path: "/missing/fusion-body.json")
  end

  test "fails explicitly when the full website body is invalid JSON" do
    workspace = "fusion-invalid-body-#{System.unique_integer([:positive])}"

    path =
      Path.join(System.tmp_dir!(), "fusion-invalid-#{System.unique_integer([:positive])}.json")

    File.write!(path, "not-json")
    on_exit(fn -> File.rm(path) end)

    assert {:error, {:invalid_seed_body, %Jason.DecodeError{}}} =
             FusionSeed.run(workspace: workspace, body_path: path)
  end

  test "fails explicitly when the full website CSS is missing" do
    workspace = "fusion-missing-css-#{System.unique_integer([:positive])}"

    assert {:error, {:seed_file, :css, :enoent}} =
             FusionSeed.run(workspace: workspace, css_path: "/missing/fusion-shell.css")
  end

  defp seed_path(file) do
    :ezagent_plugin_hello
    |> :code.priv_dir()
    |> Path.join("seed_page")
    |> Path.join(file)
  end
end
