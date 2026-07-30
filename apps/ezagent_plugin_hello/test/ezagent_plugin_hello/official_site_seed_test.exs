defmodule EzagentPluginHello.OfficialSiteSeedTest do
  @moduledoc """
  The governed 官网 deploy-seed invariant: `OfficialSiteSeed.ensure/0`
  provisions `session://ezagent/hello/ezagent-official` (the ruihua marketing
  page + greeter) in the hello HOME workspace when it is ABSENT — the self-heal
  a reseed depends on — and SKIPS the re-drive when the site already has a
  page, so a plain reboot never clobbers a live `refresh_hello_site.exs`
  refresh.

  hello-A: the 官网 is an ezagent-MEMBER session (owner = the home workspace's
  founder, falling back to `entity://ezagent/user/lin_yilun`), never the
  `system`-pinned singleton it replaced.
  """
  use EzagentCore.DataCase, async: false

  alias Ezagent.Entity.{Profile, User}
  alias Ezagent.Socialware.ExternalFeed
  alias EzagentPluginHello.OfficialSiteSeed

  setup do
    :ok = EzagentPluginHello.TestCatalog.import!()
    {:ok, _} = Application.ensure_all_started(:ezagent_domain_agent)
    {:ok, _} = Application.ensure_all_started(:ezagent_plugin_curl_agent)
    {:ok, _} = Application.ensure_all_started(:ezagent_plugin_kanban)

    Enum.each(EzagentPluginHello.Application.roles(), fn recipe ->
      {:ok, _} = Ezagent.Agent.RecipeRegistry.seed_role_if_absent(recipe)
    end)

    # Stale-Kind hygiene: sibling tests in this BEAM (the credential-source +
    # workspace-isolation integration tests) create the SAME home-workspace /
    # lin_yilun / 官网-session names; their DB rows roll back with the sandbox
    # but the live Kind processes (and the signed caps/keys in their state)
    # survive, surfacing as `:invalid_cap_signature` here. Terminate them so
    # every create below is a FRESH spawn consistent with this transaction.
    home = EzagentPluginHello.home_workspace()

    Enum.each(
      [
        Ezagent.URI.session(home, :hello, "ezagent-official"),
        Ezagent.URI.entity(home, :user, "lin_yilun"),
        Ezagent.URI.workspace(home)
      ],
      &terminate/1
    )

    # Isolate this test to the SITE-provisioning invariant. `ensure/0`'s second
    # step wires the DeepSeek credential source, but that path (a) has its own
    # coverage (`HelloCredentialSourceTest`) and (b) spawns a source agent +
    # workspace-shared pointer into the home workspace whose ETS registrations
    # survive the DataCase transaction and leak into sibling tests' cap-signing.
    # With no key, `ensure_deepseek_source/0` is a no-op (`{:ok, :no_env_key}`)
    # and the `llm` member keyless-spawns — the page still provisions, which is
    # all this invariant asserts.
    prev_key = System.get_env("DEEPSEEK_API_KEY")
    System.delete_env("DEEPSEEK_API_KEY")

    on_exit(fn ->
      if prev_key, do: System.put_env("DEEPSEEK_API_KEY", prev_key)
    end)

    # The 官网 owner (the lin_yilun fallback on this founder-less test stack)
    # must be a REAL user — the member-cap grant flow absorbs caps into the
    # owner entity at materialize time (`identity.absorb_cap`), which fails
    # `:no_such_actor` for a URI with no users row. On deploys lin_yilun is a
    # real ezagent-workspace user; create the row here the same way.
    owner = Ezagent.URI.entity(EzagentPluginHello.home_workspace(), :user, "lin_yilun")
    {:ok, _} = Ezagent.Users.create(owner, nil, [], email_verified: false)
    email = "official-founder@example.test"

    {:ok, _} =
      Profile.upsert(%{entity_uri: owner, display_name: "Official founder", email: email})

    previous = Application.get_env(:ezagent_plugin_hello, :official_site_founder_email)
    Application.put_env(:ezagent_plugin_hello, :official_site_founder_email, email)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:ezagent_plugin_hello, :official_site_founder_email, previous),
        else: Application.delete_env(:ezagent_plugin_hello, :official_site_founder_email)
    end)

    :ok
  end

  test "the site URI tracks the single home-workspace source (split-brain invariant leg)" do
    site_uri = OfficialSiteSeed.site_uri()
    home = EzagentPluginHello.home_workspace()

    assert site_uri == Ezagent.URI.session(home, :hello, "ezagent-official")
    assert Ezagent.Capability.workspace_of(site_uri) == Ezagent.URI.workspace(home)
  end

  test "provisions ezagent/hello/ezagent-official from absence, then skips when already present" do
    site_uri = OfficialSiteSeed.site_uri()
    assert site_uri == Ezagent.URI.session("ezagent", :hello, "ezagent-official")

    # Precondition — the 官网 is absent (nothing else provisions it).
    refute site_page_present?(site_uri)

    # Self-heal: absent → provision the greeter session + drive the ruihua page.
    assert {:ok, {:provisioned, ^site_uri, turn_id}} = OfficialSiteSeed.ensure()
    assert is_binary(turn_id) and turn_id != ""

    # hello-A — the session owner is an ezagent principal (the home workspace's
    # founder, or the lin_yilun fallback on this founder-less test stack),
    # NEVER the system admin.
    assert {:ok, owner_uri} = Ezagent.Entity.Session.owner(site_uri)
    assert Ezagent.Capability.workspace_of(owner_uri) == Ezagent.URI.workspace("ezagent")
    refute URI.to_string(owner_uri) == URI.to_string(User.admin_uri())

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

  defp terminate(%URI{} = uri) do
    case Ezagent.KindRegistry.lookup(uri) do
      {:ok, pid} -> if Process.alive?(pid), do: Ezagent.Kind.terminate(uri)
      _ -> :ok
    end
  end
end
