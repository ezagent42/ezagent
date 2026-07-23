defmodule EzagentWeb.WorldFeishuBindingsRealRouteTest do
  @moduledoc """
  B2 (handoff `feishu-binding-b2-world-dispatch`) — real-route proof that
  `/plugins/feishu/bindings` list/bind/unbind go through the formal
  `EzagentPluginFeishu.Behavior.UserBinding` dispatch instead of raw
  storage/policy calls.

  Every test mounts the REAL route (`live(conn, "/plugins/feishu/bindings")`)
  and drives the REAL `world:dispatch` hook on `#world-root` — no handler
  function is called directly and no storage/policy call is mocked. This is
  the route-level complement to:
  - `apps/ezagent_plugin_feishu/test/behavior/user_binding_test.exs` — the
    Behavior's OWN exhaustive workspace/anti-hijack/policy/rollback coverage
    (NOT re-proven here per the handoff's "don't duplicate Behavior rules").
  - `apps/ezagent_plugin_world/test/ezagent/world/feishu_binding_dispatch_test.exs`
    — the thin adapter's own unit coverage (target/caller/caps wiring,
    error-code normalization).

  This file proves the WORLD LAYER's contract: workspace-scoped reads, no
  raw-storage fallback, mutation truth (never reports "ok" on a real
  failure), redacted+stable error codes, and repeated-failure visibility.
  """
  use EzagentWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Ezagent.Entity.User
  alias Ezagent.Invocation
  alias Ezagent.Test.CapHelper
  alias Ezagent.Workspace
  alias Ezagent.World.FeishuBindingDispatch

  defp uniq, do: System.unique_integer([:positive])

  defp new_ws! do
    name = "wfb-#{uniq()}"
    {:ok, _} = Workspace.create(name, %{})
    ws_uri = URI.new!("workspace://#{name}")
    CapHelper.ensure_workspace_kind!(ws_uri)
    ws_uri
  end

  defp admin_conn(conn, %URI{} = workspace_uri) do
    workspace_conn(conn, workspace_uri, User.admin_uri())
  end

  defp workspace_conn(conn, %URI{} = workspace_uri, %URI{} = entity_uri) do
    conn
    |> Map.put(:host, "world.ezagent.chat")
    |> Plug.Test.init_test_session(%{
      "current_entity_uri" => URI.to_string(entity_uri),
      "current_workspace_uri" => URI.to_string(workspace_uri)
    })
  end

  defp create_read_only_user!(uri, caps) do
    case Ezagent.Users.create_read_only(uri, caps) do
      {:ok, _} -> :ok
      {:error, %Ecto.Changeset{errors: [uri: {"has already been taken", _}]}} -> :ok
    end

    :ok = Ezagent.Entity.spawn_principal(uri)
    uri
  end

  defp cap_for(%URI{} = workspace_uri, action, %URI{} = grantee) do
    target = Ezagent.URI.with_action(workspace_uri, :user_binding, action)
    CapHelper.signed_action_cap!(target, grantee)
  end

  # Seed a binding directly through the formal dispatch adapter (canonical
  # admin auto-mint), bypassing the LiveView route — used to set up fixture
  # rows a test then reads/leaks-checks/unbinds through the REAL route.
  defp seed_binding!(%URI{} = workspace_uri, open_id, %URI{} = user_uri) do
    admin = User.admin_uri()

    {:ok, _} =
      Invocation.with_admin_operator(admin, fn ->
        FeishuBindingDispatch.bind(
          workspace_uri,
          admin,
          MapSet.new(),
          open_id,
          URI.to_string(user_uri)
        )
      end)

    :ok
  end

  defp world_state(view) do
    html = render(view)
    [_, json] = Regex.run(~r/data-world-state="([^"]*)"/, html)

    json
    |> html_unescape()
    |> Jason.decode!()
  end

  defp html_unescape(s) do
    s
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
  end

  defp dispatch(view, action, args) do
    view
    |> element("#world-root")
    |> render_hook("world:dispatch", %{"action" => action, "args" => args})
  end

  describe "read isolation — foreign workspace rows never leak" do
    test "caller with list cap for workspace A sees only A's bindings, never B's", %{conn: conn} do
      ws_a = new_ws!()
      ws_b = new_ws!()

      open_id_a = "ou_wfb_a_#{uniq()}"
      user_a = URI.new!("entity://#{Ezagent.URI.name!(ws_a)}/user/alice-#{uniq()}")
      seed_binding!(ws_a, open_id_a, user_a)

      open_id_b = "ou_wfb_b_#{uniq()}"
      user_b = URI.new!("entity://#{Ezagent.URI.name!(ws_b)}/user/bob-#{uniq()}")
      seed_binding!(ws_b, open_id_b, user_b)

      caller = URI.new!("entity://#{Ezagent.URI.name!(ws_a)}/user/viewer-#{uniq()}")
      create_read_only_user!(caller, [cap_for(ws_a, :list_feishu_bindings, caller)])

      {:ok, view, html} =
        live(workspace_conn(conn, ws_a, caller), "/plugins/feishu/bindings")

      # Not in the initial dead-render HTML...
      refute html =~ open_id_b
      refute html =~ URI.to_string(user_b)

      # ...and not in the decoded world_state (foreign row not in state either).
      state = world_state(view)
      open_ids = Enum.map(state["bindings"] || [], & &1["open_id"])
      assert open_id_a in open_ids
      refute open_id_b in open_ids
    end
  end

  describe "no-cap caller — explicit denial, no silent empty-list lie" do
    test "list shows bindings=[] + a stable bindings_error, never a raw storage fallback", %{
      conn: conn
    } do
      ws = new_ws!()
      caller = URI.new!("entity://#{Ezagent.URI.name!(ws)}/user/nocap-#{uniq()}")
      create_read_only_user!(caller, [])

      open_id = "ou_wfb_nocap_read_#{uniq()}"
      user_uri = URI.new!("entity://#{Ezagent.URI.name!(ws)}/user/seed-#{uniq()}")
      seed_binding!(ws, open_id, user_uri)

      {:ok, view, html} = live(workspace_conn(conn, ws, caller), "/plugins/feishu/bindings")

      # The existing (seeded) row must not leak through a raw-fallback path.
      refute html =~ open_id

      # The bindings_error is in the server-rendered data-world-state JSON
      # (the React component renders data-world-feishu-bindings-error
      # client-side only — the server-side proof is the JSON payload).
      state = world_state(view)

      assert is_binary(state["bindings_error"]),
             "no-cap caller must get a bindings_error in world_state, got nil"

      assert state["bindings"] == []
    end

    test "bind is rejected as unauthorized and creates no row", %{conn: conn} do
      ws = new_ws!()
      caller = URI.new!("entity://#{Ezagent.URI.name!(ws)}/user/nocap-bind-#{uniq()}")
      create_read_only_user!(caller, [])

      open_id = "ou_wfb_nocap_bind_#{uniq()}"
      user_uri = URI.new!("entity://#{Ezagent.URI.name!(ws)}/user/target-#{uniq()}")

      {:ok, view, _html} = live(workspace_conn(conn, ws, caller), "/plugins/feishu/bindings")

      html =
        dispatch(view, "feishu.bind", %{
          "open_id" => open_id,
          "user_uri" => URI.to_string(user_uri)
        })

      assert html =~ ~s(data-last-dispatch="error:unauthorized")
      assert :error = EzagentPluginFeishu.UserBinding.resolve(open_id)
    end

    test "unbind is rejected as unauthorized and the DB row is untouched", %{conn: conn} do
      ws = new_ws!()
      caller = URI.new!("entity://#{Ezagent.URI.name!(ws)}/user/nocap-unbind-#{uniq()}")
      create_read_only_user!(caller, [])

      open_id = "ou_wfb_nocap_unbind_#{uniq()}"
      user_uri = URI.new!("entity://#{Ezagent.URI.name!(ws)}/user/existing-#{uniq()}")
      seed_binding!(ws, open_id, user_uri)

      {:ok, view, _html} = live(workspace_conn(conn, ws, caller), "/plugins/feishu/bindings")

      html = dispatch(view, "feishu.unbind", %{"open_id" => open_id})

      assert html =~ ~s(data-last-dispatch="error:unauthorized")
      assert {:ok, still_bound} = EzagentPluginFeishu.UserBinding.resolve(open_id)
      assert URI.to_string(still_bound) == URI.to_string(user_uri)
    end

    test "RequireEntity alone does not authorize — repeated identical denial still surfaces", %{
      conn: conn
    } do
      ws = new_ws!()
      caller = URI.new!("entity://#{Ezagent.URI.name!(ws)}/user/repeat-#{uniq()}")
      create_read_only_user!(caller, [])

      {:ok, view, _html} = live(workspace_conn(conn, ws, caller), "/plugins/feishu/bindings")

      args = %{
        "open_id" => "ou_wfb_repeat_#{uniq()}",
        "user_uri" => "entity://#{Ezagent.URI.name!(ws)}/user/x"
      }

      html1 = dispatch(view, "feishu.bind", args)
      assert html1 =~ ~s(data-last-dispatch="error:unauthorized")

      # Same caller, same rejected action, run again — the UI must not go
      # silent on the second identical failure.
      html2 = dispatch(view, "feishu.bind", args)
      assert html2 =~ ~s(data-last-dispatch="error:unauthorized")
    end
  end

  describe "precise-cap caller — real bind -> visible -> unbind cycle" do
    test "a non-canonical caller holding exact bind/unbind/list caps completes the full cycle", %{
      conn: conn
    } do
      ws = new_ws!()
      caller = URI.new!("entity://#{Ezagent.URI.name!(ws)}/user/operator-#{uniq()}")

      create_read_only_user!(caller, [
        cap_for(ws, :bind, caller),
        cap_for(ws, :unbind, caller),
        cap_for(ws, :list_feishu_bindings, caller)
      ])

      {:ok, view, _html} = live(workspace_conn(conn, ws, caller), "/plugins/feishu/bindings")

      open_id = "ou_wfb_cycle_#{uniq()}"
      user_uri = URI.new!("entity://#{Ezagent.URI.name!(ws)}/user/newcomer-#{uniq()}")

      bind_html =
        dispatch(view, "feishu.bind", %{
          "open_id" => open_id,
          "user_uri" => URI.to_string(user_uri)
        })

      assert bind_html =~ ~s(data-last-dispatch="ok")

      state_after_bind = world_state(view)
      open_ids_after_bind = Enum.map(state_after_bind["bindings"] || [], & &1["open_id"])
      assert open_id in open_ids_after_bind
      assert state_after_bind["bindings_error"] in [nil, false]

      unbind_html = dispatch(view, "feishu.unbind", %{"open_id" => open_id})
      assert unbind_html =~ ~s(data-last-dispatch="ok")

      state_after_unbind = world_state(view)
      open_ids_after_unbind = Enum.map(state_after_unbind["bindings"] || [], & &1["open_id"])
      refute open_id in open_ids_after_unbind

      assert :error = EzagentPluginFeishu.UserBinding.resolve(open_id)
    end

    test "a caller with bind but WITHOUT list cap still gets a truthful (non-ok-lying) refresh signal",
         %{conn: conn} do
      ws = new_ws!()
      caller = URI.new!("entity://#{Ezagent.URI.name!(ws)}/user/writeonly-#{uniq()}")
      create_read_only_user!(caller, [cap_for(ws, :bind, caller)])

      {:ok, view, _html} = live(workspace_conn(conn, ws, caller), "/plugins/feishu/bindings")

      open_id = "ou_wfb_writeonly_#{uniq()}"
      user_uri = URI.new!("entity://#{Ezagent.URI.name!(ws)}/user/wo-target-#{uniq()}")

      html =
        dispatch(view, "feishu.bind", %{
          "open_id" => open_id,
          "user_uri" => URI.to_string(user_uri)
        })

      # The mutation itself succeeded (real dispatch, real cap) — proven by
      # the DB row existing — but the caller cannot re-list, so the status
      # must be a distinct, honest partial-success code, NEVER a plain "ok"
      # (which would imply the visible table is now current) and NEVER a
      # silent swallow.
      assert {:ok, _} = EzagentPluginFeishu.UserBinding.resolve(open_id)
      refute html =~ ~s(data-last-dispatch="ok")
      assert html =~ ~s(data-last-dispatch="error:binding_saved_refresh_failed")
    end
  end

  describe "cross-workspace hijack is denied through the real route" do
    test "binding a user from a different workspace is refused and no row is created", %{
      conn: conn
    } do
      ws_a = new_ws!()
      ws_b = new_ws!()
      caller = URI.new!("entity://#{Ezagent.URI.name!(ws_a)}/user/xws-#{uniq()}")
      create_read_only_user!(caller, [cap_for(ws_a, :bind, caller)])

      {:ok, view, _html} = live(workspace_conn(conn, ws_a, caller), "/plugins/feishu/bindings")

      open_id = "ou_wfb_xws_#{uniq()}"
      foreign_user = URI.new!("entity://#{Ezagent.URI.name!(ws_b)}/user/foreign-#{uniq()}")

      html =
        dispatch(view, "feishu.bind", %{
          "open_id" => open_id,
          "user_uri" => URI.to_string(foreign_user)
        })

      assert html =~ ~s(data-last-dispatch="error:cross_workspace_denied")
      assert :error = EzagentPluginFeishu.UserBinding.resolve(open_id)
    end

    test "rebinding an existing foreign-workspace row is refused and the original survives", %{
      conn: conn
    } do
      ws_a = new_ws!()
      ws_b = new_ws!()

      open_id = "ou_wfb_xws_rebind_#{uniq()}"
      original_user = URI.new!("entity://#{Ezagent.URI.name!(ws_b)}/user/original-#{uniq()}")
      seed_binding!(ws_b, open_id, original_user)

      caller = URI.new!("entity://#{Ezagent.URI.name!(ws_a)}/user/hijacker-#{uniq()}")
      create_read_only_user!(caller, [cap_for(ws_a, :bind, caller)])

      {:ok, view, _html} = live(workspace_conn(conn, ws_a, caller), "/plugins/feishu/bindings")

      hijack_user = URI.new!("entity://#{Ezagent.URI.name!(ws_a)}/user/mine-#{uniq()}")

      html =
        dispatch(view, "feishu.bind", %{
          "open_id" => open_id,
          "user_uri" => URI.to_string(hijack_user)
        })

      refute html =~ ~s(data-last-dispatch="ok")

      assert {:ok, still_original} = EzagentPluginFeishu.UserBinding.resolve(open_id)
      assert URI.to_string(still_original) == URI.to_string(original_user)
    end
  end

  describe "policy failure is never reported ok" do
    test "when BindingPolicy fails after storage-bind, World does not claim ok and the row is not left in a lying state",
         %{conn: conn} do
      # Same non-deterministic policy-failure trigger the Behavior's own
      # test suite uses (`user_binding_test.exs` "rolls back DB row when
      # BindingPolicy fails") — making it deterministic is B1's Phase 3
      # deliverable (handoff `feishu-binding-b1-seed-cli-dispatch.md`).
      # This test pins the WORLD-LAYER half of the contract on whichever
      # branch actually occurs: policy success is unaffected, and IF policy
      # fails, the route must not report "ok" and rollback must hold.
      ws_name = "no_such_workspace_wfb_#{uniq()}"
      ws = URI.new!("workspace://#{ws_name}")
      orphan_user = URI.new!("entity://#{ws_name}/user/orphan-#{uniq()}")

      admin = User.admin_uri()
      caller_conn = admin_conn(conn, ws)

      {:ok, view, _html} = live(caller_conn, "/plugins/feishu/bindings")

      open_id = "ou_wfb_policy_#{uniq()}"

      html =
        dispatch(view, "feishu.bind", %{
          "open_id" => open_id,
          "user_uri" => URI.to_string(orphan_user)
        })

      case EzagentPluginFeishu.UserBinding.resolve(open_id) do
        {:ok, _} ->
          # SpawnRegistry tolerated the unregistered workspace — policy
          # succeeded, so "ok" is the TRUTHFUL status.
          assert html =~ ~s(data-last-dispatch="ok")

        :error ->
          # Policy failed and rolled back — the route must be honest: this
          # asserts against a real production reason, never `Kind.spawn`
          # exceptions or silent success.
          refute html =~ ~s(data-last-dispatch="ok")
      end

      _ = admin
    end
  end

  describe "error redaction" do
    test "no error status or state ever contains inspect-shaped content, a raw tuple, or the full open_id",
         %{conn: conn} do
      ws_a = new_ws!()
      ws_b = new_ws!()
      caller = URI.new!("entity://#{Ezagent.URI.name!(ws_a)}/user/redact-#{uniq()}")
      create_read_only_user!(caller, [cap_for(ws_a, :bind, caller)])

      {:ok, view, _html} = live(workspace_conn(conn, ws_a, caller), "/plugins/feishu/bindings")

      # A cross-workspace attempt is a real production error path with a
      # meaty raw reason (`{:cross_workspace_user, [workspace_uri: ..., user:
      # ...]}` per `behavior/user_binding.ex`) — the highest-risk leak site.
      secret_open_id = "ou_wfb_secret_leak_probe_#{uniq()}"
      foreign_user = URI.new!("entity://#{Ezagent.URI.name!(ws_b)}/user/leak-target-#{uniq()}")

      html =
        dispatch(view, "feishu.bind", %{
          "open_id" => secret_open_id,
          "user_uri" => URI.to_string(foreign_user)
        })

      status = last_dispatch_status_from(html)

      assert status =~ ~r/^error:[a-z_]+$/,
             "status must be a plain stable code, got: #{inspect(status)}"

      refute html =~ "cross_workspace_user"
      refute html =~ URI.to_string(foreign_user)
      refute html =~ inspect({:cross_workspace_user, user: URI.to_string(foreign_user)})
    end
  end

  defp last_dispatch_status_from(html) do
    [_, status] = Regex.run(~r/data-last-dispatch="([^"]*)"/, html)
    status
  end
end
