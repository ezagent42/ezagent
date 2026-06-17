defmodule EzagentWeb.FastAgentDispatchTest do
  @moduledoc """
  Re-route Phase 2 E2E: the Fast Agent editor (`FastAgentLive`, a real
  sidebar-linked admin page) writes the tenant's fast-ack prompt through
  ContentAdmin dispatch — NOT a direct File.write. Proves end-to-end that:

  - an admin holding the tenant's ContentAdmin cap → write lands (file changes
    on disk via the dispatched handler)
  - an admin WITHOUT the tenant's cap → write is denied (the old gap: any admin
    could write any tenant's prompt, with no per-workspace cap check)

  Self-seeds (workspace + users + temp sandbox), so no `mix ezagent.demo.*`
  prerequisite. Umbrella-only — needs the full stack for dispatch registration.
  """
  use EzagentWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias EzagentPluginContent.Tenant.TenantRuntime

  @moduletag :umbrella_only
  @moduletag timeout: 120_000

  @tid "fast-reroute-e2e"

  setup %{conn: conn} do
    Ecto.Adapters.SQL.Sandbox.mode(EzagentCore.Repo, {:shared, self()})

    # Isolated tenant_base_dir so the dispatched write is assertable + cleaned.
    tmp = Path.join(System.tmp_dir!(), "fast_e2e_#{System.unique_integer([:positive])}")
    prev = Application.get_env(:ezagent_plugin_content, :tenant_base_dir)
    Application.put_env(:ezagent_plugin_content, :tenant_base_dir, tmp)
    File.mkdir_p!(Path.join([tmp, @tid, "sandbox", "config"]))

    on_exit(fn ->
      if prev, do: Application.put_env(:ezagent_plugin_content, :tenant_base_dir, prev)
      File.rm_rf!(tmp)
    end)

    ws = Ezagent.URI.workspace(@tid)

    # Ensure the content plugin is booted so ContentAdmin is registered for the
    # Workspace Kind (its behaviors/0 → Plugin.boot registers dispatch routes).
    {:ok, _} = Application.ensure_all_started(:ezagent_plugin_content)

    # Seed the workspace Kind (the dispatch target).
    case Ezagent.Workspace.create(@tid, %{}) do
      {:ok, _} -> :ok
      {:error, :workspace_exists} -> :ok
      {:error, {:already_started, _}} -> :ok
      other -> raise "seed workspace failed: #{inspect(other)}"
    end

    # Both users are system members (pass :require_admin); they differ only in
    # holding THIS tenant's ContentAdmin cap.
    admin = "entity://system/user/fast-admin-#{System.unique_integer([:positive])}"
    noncap = "entity://system/user/fast-noncap-#{System.unique_integer([:positive])}"
    {:ok, _} = Ezagent.Users.create(admin, nil, EzagentPluginAutoservice.Roles.bundle(:admin, ws))
    {:ok, _} = Ezagent.Users.create(noncap, nil, [])

    {:ok, conn: conn, admin: admin, noncap: noncap}
  end

  defp authed(conn, entity) do
    Plug.Test.init_test_session(conn, %{
      "current_entity_uri" => entity,
      "current_workspace_uri" => "workspace://system"
    })
  end

  defp prompt_path,
    do: Path.join([TenantRuntime.sandbox_path(@tid), "config", "fast_ack_prompt.md"])

  alias EzagentPluginLiveview.Admin.ContentAdminClient

  test "the seeded admin's caps authorize ContentAdmin on this workspace (diagnostic)", %{
    admin: admin,
    noncap: noncap
  } do
    ws = Ezagent.URI.workspace(@tid)
    admin_caps = ContentAdminClient.load_caps(admin)
    assert ContentAdminClient.writable?(admin_caps, ws), "admin caps should authorize writes"
    refute ContentAdminClient.writable?(ContentAdminClient.load_caps(noncap), ws)

    # Direct dispatch (outside the LV) confirms the action resolves + authorizes.
    assert {:ok, _} =
             ContentAdminClient.dispatch(ws, admin, admin_caps, :write_fast_prompt, %{
               content: "diag"
             })
  end

  test "admin with the tenant cap writes the fast prompt via ContentAdmin dispatch", %{
    conn: conn,
    admin: admin
  } do
    {:ok, lv, _html} = live(authed(conn, admin), "/admin/autoservice/tenants/#{@tid}/agent/fast")

    content = "您好，正在为您接入人工…(#{System.unique_integer([:positive])})"

    lv |> form("form", %{"content" => content}) |> render_submit()

    # The dispatched ContentAdmin.write_fast_prompt handler wrote the sandbox file.
    assert File.read!(prompt_path()) == content
  end

  test "admin WITHOUT the tenant cap is denied (no per-workspace write)", %{
    conn: conn,
    noncap: noncap
  } do
    {:ok, lv, _html} = live(authed(conn, noncap), "/admin/autoservice/tenants/#{@tid}/agent/fast")

    lv |> form("form", %{"content" => "unauthorized write attempt"}) |> render_submit()

    refute File.exists?(prompt_path())
  end
end
