defmodule EzagentPluginHello.OfficialSiteSeedTest do
  @moduledoc """
  The governed 官网 deploy-seed invariant: `OfficialSiteSeed.ensure/0`
  provisions `session://system/hello/web` (the ruihua marketing page + greeter)
  when it is ABSENT — the self-heal a reseed depends on — and SKIPS the re-drive
  when the site already has a page, so a plain reboot never clobbers a live
  `refresh_hello_site.exs` refresh.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Entity.User
  alias Ezagent.Socialware.ExternalFeed
  alias EzagentPluginHello.OfficialSiteSeed

  setup do
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_agent)
    {:ok, _} = Application.ensure_all_started(:ezagent_plugin_curl_agent)
    {:ok, _} = Application.ensure_all_started(:ezagent_plugin_kanban)

    Enum.each(EzagentPluginHello.Application.roles(), fn recipe ->
      {:ok, _} = Ezagent.Agent.RecipeRegistry.seed_role_if_absent(recipe)
    end)

    # Isolate this test to the SITE-provisioning invariant. `ensure/0`'s first
    # step wires the DeepSeek credential source, but that path (a) has its own
    # coverage (`HelloCredentialSourceTest`) and (b) spawns a source agent +
    # workspace-shared pointer into the LITERAL `"system"` workspace whose ETS
    # registrations survive the DataCase transaction and leak into sibling
    # tests' cap-signing. With no key, `ensure_deepseek_source/0` is a no-op
    # (`{:ok, :no_env_key}`) and the `llm` member keyless-spawns — the page
    # still provisions, which is all this invariant asserts.
    prev_key = System.get_env("DEEPSEEK_API_KEY")
    System.delete_env("DEEPSEEK_API_KEY")

    on_exit(fn ->
      if prev_key, do: System.put_env("DEEPSEEK_API_KEY", prev_key)
    end)

    :ok
  end

  test "provisions system/hello/web from absence, then skips when already present" do
    site_uri = OfficialSiteSeed.site_uri()
    assert site_uri == Ezagent.URI.session("system", :hello, "web")

    # Precondition — the 官网 is absent (nothing else provisions system/hello/web).
    refute site_page_present?(site_uri)

    # Self-heal: absent → provision the greeter session + drive the ruihua page.
    assert {:ok, {:provisioned, ^site_uri, turn_id}} = OfficialSiteSeed.ensure()
    assert is_binary(turn_id) and turn_id != ""

    # The committed ruihua marketing page ("组织的 IDE") is on the Surface.
    expected_body = seed_path("body.json") |> File.read!() |> Jason.decode!()
    expected_css = seed_path("shell.css") |> File.read!()

    assert {:ok, snapshot} = ExternalFeed.snapshot(site_uri, User.admin_uri())
    assert snapshot.page == expected_body
    assert snapshot.shell_css == expected_css

    # Absence gate: a second run finds the page present and SKIPS the re-drive
    # (a plain reboot preserves a live GitHub-data refresh).
    assert {:ok, {:already_provisioned, ^site_uri}} = OfficialSiteSeed.ensure()

    # And the page is unchanged after the skipped run.
    assert {:ok, snapshot2} = ExternalFeed.snapshot(site_uri, User.admin_uri())
    assert snapshot2.page == expected_body
  end

  # Mirrors `OfficialSiteSeed`'s internal absence gate.
  defp site_page_present?(site_uri) do
    match?(
      {:ok, %{page: page}} when not is_nil(page),
      ExternalFeed.snapshot(site_uri, User.admin_uri())
    )
  end

  defp seed_path(file) do
    :ezagent_plugin_hello
    |> :code.priv_dir()
    |> Path.join("seed_page")
    |> Path.join(file)
  end
end
