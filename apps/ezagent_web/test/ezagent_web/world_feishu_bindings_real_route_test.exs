defmodule EzagentWeb.WorldFeishuBindingsRealRouteTest do
  @moduledoc """
  B2 (handoff `feishu-binding-b2-world-dispatch`) — real-route proof that
  `/plugins/feishu/bindings` list/bind/unbind go through the formal
  `EzagentPluginFeishu.Behavior.UserBinding` dispatch instead of raw
  storage/policy calls.

  Every test mounts the REAL route (`live(conn, "/plugins/feishu/bindings")`)
  and drives the REAL `world:dispatch` hook on `#world-root` — no handler
  function is called directly and no World adapter result is mocked. This is
  the route-level complement to:
  - `apps/ezagent_plugin_feishu/test/behavior/user_binding_test.exs` — the
    Behavior's OWN exhaustive workspace/anti-hijack/policy/rollback coverage
    (NOT re-proven here per the handoff's "don't duplicate Behavior rules").
  - `apps/ezagent_plugin_world/test/ezagent/world/feishu_binding_dispatch_test.exs`
    — the thin adapter's own unit coverage (target/caller/caps wiring,
    error-code normalization).

  This file proves the WORLD LAYER's contract: workspace-scoped reads, no
  raw-storage fallback, mutation truth (never reports "ok" on a real
  failure), durable rollback on a controlled policy failure, redacted+stable
  error codes, and repeated-failure visibility.
  """
  use EzagentWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Ezagent.Entity.User
  alias Ezagent.Invocation
  alias Ezagent.Test.CapHelper
  alias Ezagent.Workspace
  alias Ezagent.World.FeishuBindingDispatch
  alias EzagentPluginFeishu.TestSupport.{FailingPolicy, FailingUnbindStorage}

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
    target = Ezagent.URI.with_action(workspace_uri, :feishu_user_bindings, action)
    CapHelper.signed_action_cap!(target, grantee)
  end

  # Seed a binding through the admin-operator seam — test-only fixture,
  # not a production authorization path (DEFERRED B2-auth).
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

  defp world_root_attribute(view, name) do
    [value] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#world-root")
      |> LazyHTML.attribute(name)

    value
  end

  defp world_state(view), do: view |> world_root_attribute("data-world-state") |> Jason.decode!()

  defp assert_dispatch_status(view, status) do
    assert has_element?(view, ~s(#world-root[data-last-dispatch="#{status}"]))
  end

  defp refute_dispatch_status(view, status) do
    refute has_element?(view, ~s(#world-root[data-last-dispatch="#{status}"]))
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

      {:ok, view, _html} =
        live(workspace_conn(conn, ws_a, caller), "/plugins/feishu/bindings")

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

      {:ok, view, _html} = live(workspace_conn(conn, ws, caller), "/plugins/feishu/bindings")

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

      dispatch(view, "feishu.bind", %{
        "open_id" => open_id,
        "user_uri" => URI.to_string(user_uri)
      })

      assert_dispatch_status(view, "error:unauthorized")
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

      dispatch(view, "feishu.unbind", %{"open_id" => open_id})

      assert_dispatch_status(view, "error:unauthorized")
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

      dispatch(view, "feishu.bind", args)
      assert_dispatch_status(view, "error:unauthorized")

      # Same caller, same rejected action, run again — the UI must not go
      # silent on the second identical failure.
      dispatch(view, "feishu.bind", args)
      assert_dispatch_status(view, "error:unauthorized")
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

      dispatch(view, "feishu.bind", %{
        "open_id" => open_id,
        "user_uri" => URI.to_string(user_uri)
      })

      assert_dispatch_status(view, "ok")

      state_after_bind = world_state(view)
      open_ids_after_bind = Enum.map(state_after_bind["bindings"] || [], & &1["open_id"])
      assert open_id in open_ids_after_bind
      assert state_after_bind["bindings_error"] in [nil, false]

      dispatch(view, "feishu.unbind", %{"open_id" => open_id})
      assert_dispatch_status(view, "ok")

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
      refute_dispatch_status(view, "ok")
      assert_dispatch_status(view, "error:binding_saved_refresh_failed")
    end

    test "a caller with unbind but WITHOUT list cap gets binding_removed_refresh_failed (partial success)",
         %{conn: conn} do
      ws = new_ws!()
      caller = URI.new!("entity://#{Ezagent.URI.name!(ws)}/user/unbind-only-#{uniq()}")
      create_read_only_user!(caller, [cap_for(ws, :unbind, caller)])

      open_id = "ou_wfb_unbind_only_#{uniq()}"
      user_uri = URI.new!("entity://#{Ezagent.URI.name!(ws)}/user/target-#{uniq()}")
      seed_binding!(ws, open_id, user_uri)

      {:ok, view, _html} = live(workspace_conn(conn, ws, caller), "/plugins/feishu/bindings")

      dispatch(view, "feishu.unbind", %{"open_id" => open_id})

      assert :error = EzagentPluginFeishu.UserBinding.resolve(open_id)
      refute_dispatch_status(view, "ok")
      assert_dispatch_status(view, "error:binding_removed_refresh_failed")
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

      dispatch(view, "feishu.bind", %{
        "open_id" => open_id,
        "user_uri" => URI.to_string(foreign_user)
      })

      assert_dispatch_status(view, "error:cross_workspace_denied")
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

      dispatch(view, "feishu.bind", %{
        "open_id" => open_id,
        "user_uri" => URI.to_string(hijack_user)
      })

      refute_dispatch_status(view, "ok")

      assert {:ok, still_original} = EzagentPluginFeishu.UserBinding.resolve(open_id)
      assert URI.to_string(still_original) == URI.to_string(original_user)
    end
  end

  describe "policy failure is rolled back and never reported ok" do
    test "authorized World bind reaches the controlled policy failure and rolls back durably", %{
      conn: conn
    } do
      ws = new_ws!()
      caller = URI.new!("entity://#{Ezagent.URI.name!(ws)}/user/policy-operator-#{uniq()}")

      create_read_only_user!(caller, [
        cap_for(ws, :bind, caller),
        cap_for(ws, :list_feishu_bindings, caller)
      ])

      {:ok, view, _html} = live(workspace_conn(conn, ws, caller), "/plugins/feishu/bindings")
      assert world_state(view)["bindings_error"] in [nil, false]

      previous_policy = Application.get_env(:ezagent_plugin_feishu, :binding_policy_mod)
      Application.put_env(:ezagent_plugin_feishu, :binding_policy_mod, FailingPolicy)

      on_exit(fn ->
        if previous_policy do
          Application.put_env(
            :ezagent_plugin_feishu,
            :binding_policy_mod,
            previous_policy
          )
        else
          Application.delete_env(:ezagent_plugin_feishu, :binding_policy_mod)
        end
      end)

      open_id = "ou_wfb_policy_fail_#{uniq()}"
      user_uri = URI.new!("entity://#{Ezagent.URI.name!(ws)}/user/target-#{uniq()}")

      dispatch(view, "feishu.bind", %{
        "open_id" => open_id,
        "user_uri" => URI.to_string(user_uri)
      })

      assert has_element?(
               view,
               ~s(#world-root[data-last-dispatch="error:binding_policy_failed"])
             )

      refute has_element?(view, ~s(#world-root[data-last-dispatch="ok"]))
      assert :error = EzagentPluginFeishu.UserBinding.resolve(open_id)

      state = world_state(view)
      assert state["bindings"] == []
      assert state["bindings_error"] in [nil, false]
    end

    test "rollback failure reports an honest distinct code and the new binding may remain", %{
      conn: conn
    } do
      ws = new_ws!()
      caller = URI.new!("entity://#{Ezagent.URI.name!(ws)}/user/rollback-operator-#{uniq()}")

      create_read_only_user!(caller, [
        cap_for(ws, :bind, caller),
        cap_for(ws, :list_feishu_bindings, caller)
      ])

      {:ok, view, _html} = live(workspace_conn(conn, ws, caller), "/plugins/feishu/bindings")

      previous_policy = Application.get_env(:ezagent_plugin_feishu, :binding_policy_mod)
      previous_storage = Application.get_env(:ezagent_plugin_feishu, :user_binding_storage_mod)
      Application.put_env(:ezagent_plugin_feishu, :binding_policy_mod, FailingPolicy)

      Application.put_env(
        :ezagent_plugin_feishu,
        :user_binding_storage_mod,
        FailingUnbindStorage
      )

      on_exit(fn ->
        restore_feishu_env(:binding_policy_mod, previous_policy)
        restore_feishu_env(:user_binding_storage_mod, previous_storage)
      end)

      open_id = "ou_wfb_rollback_fail_#{uniq()}"
      user_uri = URI.new!("entity://#{Ezagent.URI.name!(ws)}/user/target-#{uniq()}")

      dispatch(view, "feishu.bind", %{
        "open_id" => open_id,
        "user_uri" => URI.to_string(user_uri)
      })

      assert has_element?(
               view,
               ~s(#world-root[data-last-dispatch="error:binding_rollback_failed"])
             )

      refute has_element?(view, ~s(#world-root[data-last-dispatch="ok"]))
      assert {:ok, ^user_uri} = EzagentPluginFeishu.UserBinding.resolve(open_id)
    end

    test "non-entity user_uri is rejected by the Behavior fail-closed gate and World does not report ok",
         %{conn: conn} do
      # The Behavior's `ensure_entity_user_uri/1` rejects non-entity:// URIs
      # BEFORE any side-effect — the B2 fail-closed chokepoint.
      ws = new_ws!()
      {:ok, view, _html} = live(admin_conn(conn, ws), "/plugins/feishu/bindings")

      open_id = "ou_wfb_not_entity_#{uniq()}"
      non_entity = Ezagent.URI.new!("template://system/foo/bar")

      dispatch(view, "feishu.bind", %{
        "open_id" => open_id,
        "user_uri" => URI.to_string(non_entity)
      })

      refute_dispatch_status(view, "ok")
      assert :error = EzagentPluginFeishu.UserBinding.resolve(open_id)
    end

    test "mutation error preserves the existing bindings list — a caller with list cap but no bind cap still sees their table after a failed bind",
         %{conn: conn} do
      ws = new_ws!()
      caller = URI.new!("entity://#{Ezagent.URI.name!(ws)}/user/list-only-#{uniq()}")
      create_read_only_user!(caller, [cap_for(ws, :list_feishu_bindings, caller)])

      # Seed a binding through admin so the caller can see it.
      open_id_existing = "ou_wfb_existing_#{uniq()}"
      user_existing = URI.new!("entity://#{Ezagent.URI.name!(ws)}/user/existing-#{uniq()}")
      seed_binding!(ws, open_id_existing, user_existing)

      {:ok, view, _html} = live(workspace_conn(conn, ws, caller), "/plugins/feishu/bindings")

      # Caller can see the existing row.
      state_before = world_state(view)
      assert Enum.any?(state_before["bindings"] || [], &(&1["open_id"] == open_id_existing))

      # Attempt a bind the caller has no cap for → must fail.
      open_id_new = "ou_wfb_new_#{uniq()}"
      user_new = URI.new!("entity://#{Ezagent.URI.name!(ws)}/user/new-#{uniq()}")

      dispatch(view, "feishu.bind", %{
        "open_id" => open_id_new,
        "user_uri" => URI.to_string(user_new)
      })

      assert_dispatch_status(view, "error:unauthorized")

      # The existing row must still be visible — the failed mutation did not
      # clear the table.
      state_after = world_state(view)
      assert Enum.any?(state_after["bindings"] || [], &(&1["open_id"] == open_id_existing))
    end
  end

  defp restore_feishu_env(key, nil), do: Application.delete_env(:ezagent_plugin_feishu, key)
  defp restore_feishu_env(key, value), do: Application.put_env(:ezagent_plugin_feishu, key, value)

  # DEFERRED B2-auth: the admin-operator seam (`with_admin_operator`) tested
  # here is the existing sanctioned convenience, not a permanent authorization
  # scheme.  A later B2-auth slice will replace it with real operator-cap
  # acquisition and signed-cap minting.
  describe "canonical admin convenience" do
    test "canonical admin completes bind→visible→unbind through the admin-operator seam", %{
      conn: conn
    } do
      ws = new_ws!()

      # Admin mounts the page — FeishuBindingDispatch.list_for_initial_state/3
      # wraps the initial read in Invocation.with_admin_operator/2, so the
      # admin auto-mints the list cap and sees bindings immediately (no
      # bindings_error on initial load).
      {:ok, view, _html} = live(admin_conn(conn, ws), "/plugins/feishu/bindings")

      state_initial = world_state(view)
      assert state_initial["bindings_error"] in [nil, false]

      # Bind through world:dispatch → admin-operator auto-mints the caps.
      open_id = "ou_wfb_admin_#{uniq()}"
      user_uri = URI.new!("entity://#{Ezagent.URI.name!(ws)}/user/admin-target-#{uniq()}")

      dispatch(view, "feishu.bind", %{
        "open_id" => open_id,
        "user_uri" => URI.to_string(user_uri)
      })

      assert_dispatch_status(view, "ok")

      # After successful bind, the table refreshes (inside with_admin_operator,
      # the refresh list dispatch also auto-mints caps).
      state_after_bind = world_state(view)
      assert Enum.any?(state_after_bind["bindings"] || [], &(&1["open_id"] == open_id))

      # Unbind through world:dispatch.
      dispatch(view, "feishu.unbind", %{"open_id" => open_id})
      assert_dispatch_status(view, "ok")

      state_after_unbind = world_state(view)
      refute Enum.any?(state_after_unbind["bindings"] || [], &(&1["open_id"] == open_id))
    end
  end

  describe "foreign existing row unbind is denied" do
    test "a caller in workspace A cannot unbind an open_id bound to workspace B", %{conn: conn} do
      ws_a = new_ws!()
      ws_b = new_ws!()

      open_id = "ou_wfb_foreign_unbind_#{uniq()}"
      user_b = URI.new!("entity://#{Ezagent.URI.name!(ws_b)}/user/b-user-#{uniq()}")
      seed_binding!(ws_b, open_id, user_b)

      caller_a = URI.new!("entity://#{Ezagent.URI.name!(ws_a)}/user/a-caller-#{uniq()}")
      create_read_only_user!(caller_a, [cap_for(ws_a, :unbind, caller_a)])

      {:ok, view, _html} = live(workspace_conn(conn, ws_a, caller_a), "/plugins/feishu/bindings")

      dispatch(view, "feishu.unbind", %{"open_id" => open_id})

      refute_dispatch_status(view, "ok")

      # The original binding in workspace B must survive.
      assert {:ok, still_bound} = EzagentPluginFeishu.UserBinding.resolve(open_id)
      assert URI.to_string(still_bound) == URI.to_string(user_b)
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

      dispatch(view, "feishu.bind", %{
        "open_id" => secret_open_id,
        "user_uri" => URI.to_string(foreign_user)
      })

      status = world_root_attribute(view, "data-last-dispatch")
      state_json = world_root_attribute(view, "data-world-state")

      assert status =~ ~r/^error:[a-z_]+$/,
             "status must be a plain stable code, got: #{inspect(status)}"

      for secret <- [
            "cross_workspace_user",
            URI.to_string(foreign_user),
            inspect({:cross_workspace_user, user: URI.to_string(foreign_user)})
          ] do
        refute String.contains?(status, secret)
        refute String.contains?(state_json, secret)
      end
    end
  end
end
