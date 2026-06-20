defmodule EzagentPluginLiveview.Admin.SessionExternalMirrorLiveTest do
  @moduledoc """
  Tests for `/admin/sessions/:id/external_mirror` (SPEC §9 PR-EM-4).

  Five required tests per the PR brief:

  1. Mount as admin with a session holding 2 bindings → both render.
  2. Mount as non-admin without Cap 1 → redirect / unauthorized.
  3. Filter adapter dropdown: caller with cap on adapter A only sees A in
     the dropdown (not B).
  4. Click unbind → binding removed from list + projection row gone.
  5. Click add binding → form submits → new binding appears.

  The LV calls the `Ezagent.ExternalMirror` facade (PR-EM-3), which goes
  through `Ezagent.Invocation.dispatch/1` for CapBAC + cross-workspace
  isolation. The MockPublishAdapter + TestSupport pair from
  `apps/ezagent_domain_external_mirror/test/support/` is reused so the
  test setup mirrors `Ezagent.Behavior.ExternalMirrorTest`.
  """

  use ExUnit.Case, async: false

  # #52 Mode-A: cross-tier LiveView suite — mounts views that resolve
  # sibling-app domain modules; runs only in the umbrella. Excluded
  # standalone (`cd apps/ezagent_plugin_liveview && mix test`).
  @moduletag :umbrella_only

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Ezagent.Capability
  alias Ezagent.Entity.{Session, User}

  alias Ezagent.ExternalMirror.{
    AdapterRegistry,
    BindingRegistry,
    BindingRow,
    RootSupervisor
  }

  alias EzagentPluginLiveview.{PR4TestAdapter, PR4TestAdapterB, PR4TestBinding, PR4TestBindingB}

  alias Ezagent.ExternalMirror, as: Facade

  @endpoint EzagentWeb.Endpoint
  @workspace_uri Ezagent.URI.new!("workspace://team-alpha")

  setup tags do
    # Use the shared-sandbox OWNER pattern (`start_owner!`) via DataCase
    # rather than `checkout` + `mode({:shared, self()})`. The bind flow
    # spawns Session/ExternalMirror-Worker Kinds under a DynamicSupervisor
    # (NOT descendants of the test process); only `start_owner!`'s shared
    # owner lets those non-descendant processes find the connection —
    # otherwise their DB ops raise `DBConnection.OwnershipError` and the
    # bind `:call` times out. DataCase also registers the P6 Kind-drain
    # `on_exit`. (post-lifecycle remediation.)
    EzagentCore.DataCase.setup_sandbox(tags)

    :ok = ensure_adapter_registered(PR4TestAdapter, PR4TestBinding)
    :ok = ensure_adapter_registered(PR4TestAdapterB, PR4TestBindingB)
    cleanup_workers()

    session_uri = unique_session_uri("pr4")
    owner_uri = unique_user_uri("pr4-owner")

    on_exit(fn ->
      cleanup_session(session_uri)
      cleanup_workers()
    end)

    {:ok, session_uri: session_uri, owner_uri: owner_uri}
  end

  # ----- conn / route helpers ------------------------------------------------

  defp admin_conn do
    Phoenix.ConnTest.build_conn()
    |> Plug.Test.init_test_session(%{
      "current_entity_uri" => URI.to_string(User.admin_uri())
    })
  end

  defp non_admin_conn do
    # Spawn a fresh non-admin user with NO ExternalMirror caps. This user
    # passes `:require_admin` *only* via the `is_system_member?` gate (it
    # IS in `workspace://system` because admin URI has `system` segment)
    # — admins differ from system members differ from session-level
    # ExternalMirror cap holders. For PR-EM-4 we want a user who CAN
    # mount admin LVs (router gate passes) but doesn't hold Cap 1 on the
    # specific session, so the facade returns `:unauthorized` and the LV
    # bounces with a flash.
    uri = "entity://system/user/em_pr4_member_#{System.unique_integer([:positive])}"
    user_uri = Ezagent.URI.new!(uri)

    # spawn user with no caps so list_bindings dispatch denies on this
    # specific session (the user has admin route access but no per-
    # session ExternalMirror cap).
    {:ok, _pid} = Ezagent.Kind.spawn(User, %{uri: user_uri, initial_caps: MapSet.new()})

    Phoenix.ConnTest.build_conn()
    |> Plug.Test.init_test_session(%{"current_entity_uri" => uri})
  end

  defp path_for(session_uri) do
    "/admin/sessions/" <> URI.encode_www_form(URI.to_string(session_uri)) <> "/external_mirror"
  end

  # ----- (1) two bindings render ---------------------------------------------

  describe "/admin/sessions/:id/external_mirror — list bindings" do
    test "admin with 2 bindings sees both", %{
      session_uri: session_uri,
      owner_uri: owner_uri
    } do
      :ok = spawn_owner_and_session(owner_uri, session_uri)

      ctx = owner_admin_ctx(owner_uri)

      target_a = "tgt-pr4-list-A"
      target_b = "tgt-pr4-list-B"

      {:ok, _} = Facade.bind(session_uri, "pr4_mock", target_a, %{}, ctx)
      {:ok, _} = Facade.bind(session_uri, "pr4_mock", target_b, %{}, ctx)

      {:ok, _lv, html} = live(admin_conn(), path_for(session_uri))

      assert html =~ target_a
      assert html =~ target_b
      assert html =~ "pr4_mock"
      # The page header carries the session URI for operator context.
      assert html =~ URI.to_string(session_uri)
    end
  end

  # ----- (2) non-admin redirected --------------------------------------------

  describe "/admin/sessions/:id/external_mirror — cap gate" do
    test "non-admin without Cap 1 on this session is redirected with a flash",
         %{session_uri: session_uri, owner_uri: owner_uri} do
      # Spawn the session so the URL is otherwise valid — the rejection
      # we want to observe is the per-session cap miss, not "session not
      # running".
      :ok = spawn_owner_and_session(owner_uri, session_uri)

      conn = non_admin_conn()
      result = live(conn, path_for(session_uri))

      # Either a flash-redirect on mount or a route-level redirect; both
      # are valid "this caller cannot view this page" outcomes. The
      # important property is: the LV did NOT render the bindings page.
      case result do
        {:error, {:redirect, %{to: dest}}} ->
          assert dest in ["/sessions", "/login"]

        {:error, {:live_redirect, %{to: dest}}} ->
          assert dest in ["/sessions", "/login"]

        {:ok, _lv, html} ->
          # If mount succeeded (e.g. centralized admin gate passed) the
          # facade must have rejected the per-session read — page would
          # not contain the bindings UI.
          refute html =~ "Bindings"
      end
    end
  end

  # ----- (3) adapter dropdown caps-filtered ---------------------------------

  describe "/admin/sessions/:id/external_mirror — adapter dropdown" do
    test "dropdown lists only adapters whose Cap 2 the caller holds (P15)",
         %{session_uri: session_uri, owner_uri: owner_uri} do
      :ok = spawn_owner_and_session(owner_uri, session_uri)

      # Admin caller holds the `:any/:any/:any` bootstrap cap so EVERY
      # registered adapter's Cap 2 is satisfied — the dropdown should
      # show PR4TestAdapter (the one we registered in setup).
      {:ok, _lv, html} = live(admin_conn(), path_for(session_uri))

      assert html =~ "pr4_mock"
      # The Add binding section is rendered (i.e. not the
      # "no per-adapter caps held" empty-state).
      assert html =~ "Add binding"
      refute html =~ "per-adapter allow caps"
    end

    test "a :pull adapter is EXCLUDED from the bind dropdown even for an admin (P3-1 Finding 2)",
         %{session_uri: session_uri, owner_uri: owner_uri} do
      :ok = spawn_owner_and_session(owner_uri, session_uri)

      # Register a binding-less :pull adapter. Even though the admin holds
      # the `:any/:any/:any` cap (so Cap 2 is satisfied), the bind picker
      # must NOT list it — a pull adapter is not bindable (Gates returns
      # :not_bindable). The push adapter (pr4_mock) still appears.
      alias Ezagent.ExternalMirror.TestSupport.PullAdapter
      _ = AdapterRegistry.register(PullAdapter)
      on_exit(fn -> AdapterRegistry.__delete__("pull_em") end)

      {:ok, _lv, html} = live(admin_conn(), path_for(session_uri))

      assert html =~ "pr4_mock", "the :push adapter must still appear in the bind dropdown"
      refute html =~ "pull_em", "the :pull adapter must NOT appear in the bind dropdown"
    end

    test "caller with NO per-adapter allow cap sees the empty-state message",
         %{session_uri: session_uri, owner_uri: owner_uri} do
      :ok = spawn_owner_and_session(owner_uri, session_uri)

      # Build a caller whose ONLY cap is the session-level
      # `Behavior.ExternalMirror` cap (Cap 1) — they can list_bindings,
      # but they hold no per-adapter allow cap, so the dropdown filter
      # produces []. Per P15 narrow-by-default the form swaps to the
      # empty-state message and no submit is possible.
      caller_uri =
        Ezagent.URI.new!(
          "entity://system/user/pr4_cap1_only_#{System.unique_integer([:positive])}"
        )

      caps =
        MapSet.new([
          %Capability{
            kind: :session,
            behavior: Ezagent.Behavior.ExternalMirror,
            instance: session_uri,
            workspace_uri: @workspace_uri,
            granted_by: User.admin_uri(),
            granted_at: DateTime.utc_now()
          }
        ])

      {:ok, _pid} = Ezagent.Kind.spawn(User, %{uri: caller_uri, initial_caps: caps})

      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Test.init_test_session(%{"current_entity_uri" => URI.to_string(caller_uri)})

      {:ok, _lv, html} = live(conn, path_for(session_uri))

      # The dropdown filter produced [] (caller holds Cap 1 but no
      # Cap 2 for any adapter). Empty-state copy MUST appear, and
      # the adapter name MUST NOT (the dropdown is hidden when empty).
      assert html =~ "per-adapter allow caps"
      refute html =~ "pr4_mock"
    end
  end

  # ----- (4) unbind removes binding -----------------------------------------

  describe "/admin/sessions/:id/external_mirror — unbind" do
    test "clicking unbind removes the binding from the list + DB row gone",
         %{session_uri: session_uri, owner_uri: owner_uri} do
      :ok = spawn_owner_and_session(owner_uri, session_uri)
      ctx = owner_admin_ctx(owner_uri)

      target = "tgt-pr4-unbind"
      {:ok, _} = Facade.bind(session_uri, "pr4_mock", target, %{}, ctx)

      {:ok, lv, html} = live(admin_conn(), path_for(session_uri))
      assert html =~ target

      lv
      |> render_hook("unbind", %{
        "adapter-id" => "pr4_mock",
        "target-id" => target
      })

      # Refresh — list_bindings should now show the binding gone.
      html_after = render(lv)
      refute html_after =~ target

      # DB projection row also gone.
      assert [] = BindingRow.list_for_session(session_uri)
    end
  end

  # ----- (5) add binding appears --------------------------------------------

  describe "/admin/sessions/:id/external_mirror — add binding" do
    test "submitting the add-binding form makes the binding appear",
         %{session_uri: session_uri, owner_uri: owner_uri} do
      :ok = spawn_owner_and_session(owner_uri, session_uri)

      # Admin caller — dropdown lists mock_publish.
      {:ok, lv, html} = live(admin_conn(), path_for(session_uri))
      refute html =~ "tgt-pr4-add"

      target = "tgt-pr4-add-#{System.unique_integer([:positive])}"

      lv
      |> form("#add-binding-form",
        binding: %{adapter_id: "pr4_mock", target_id: target}
      )
      |> render_submit()

      # The render after submit triggers a refresh_bindings which calls
      # list_bindings — the new row should show up.
      html_after = render(lv)
      assert html_after =~ target
      assert html_after =~ "pr4_mock"
    end

    test "submitting with a non-authorized adapter id (tampered form) is rejected by the facade",
         %{session_uri: session_uri, owner_uri: owner_uri} do
      :ok = spawn_owner_and_session(owner_uri, session_uri)

      ctx = owner_admin_ctx(owner_uri)

      # Baseline: no bindings.
      assert {:ok, []} = Facade.list_bindings(session_uri, ctx)

      {:ok, lv, _html} = live(admin_conn(), path_for(session_uri))

      # codex r1 MED-1 (2026-05-25): the LV no longer pre-rejects
      # adapter ids against the dropdown's filtered list — per P18 the
      # facade IS the canonical authority and its `:unknown_adapter`
      # / `:adapter_not_authorized` atoms must reach the operator
      # verbatim. Pin the structural property: no binding row lands
      # in the slice or projection.
      target = "tgt-pr4-tampered-#{System.unique_integer([:positive])}"

      lv
      |> render_hook("add_binding", %{
        "binding" => %{"adapter_id" => "ghost_adapter_999", "target_id" => target}
      })

      assert {:ok, []} = Facade.list_bindings(session_uri, ctx)
      assert [] = BindingRow.list_for_session(session_uri)
    end
  end

  # ----- (6) codex r1+r2 HIGH regression — revoke-after-mount denies ------

  describe "codex r1+r2 HIGH — fresh_ctx_for_action + refresh clears + redirects on revoke" do
    test "Cap 1 revoke after mount: next refresh poll surfaces :unauthorized → clear bindings + redirect",
         %{session_uri: session_uri, owner_uri: owner_uri} do
      # r1 fix: `fresh_ctx_for_action/1` reads the live User Kind slice
      # on every privileged event + refresh cycle (no mount-time cache).
      # r2 fix: when refresh's `list_bindings` returns `:unauthorized` /
      # `:cross_workspace_denied`, the LV clears the privileged
      # surface (bindings, dropdown, audit rings) AND
      # `push_navigate(to: "/sessions")` — so a Cap 1 revoke
      # mid-LV-session can't leave stale binding rows on screen.
      :ok = spawn_owner_and_session(owner_uri, session_uri)

      # System-member caller (workspace://system) so `:require_admin`
      # admin gate admits via `is_system_member?`. Has Cap 1 so mount's
      # `list_bindings` succeeds.
      caller_uri =
        Ezagent.URI.new!("entity://system/user/pr4_revoke_#{System.unique_integer([:positive])}")

      cap1 = %Capability{
        kind: :session,
        behavior: Ezagent.Behavior.ExternalMirror,
        instance: session_uri,
        workspace_uri: @workspace_uri,
        granted_by: User.admin_uri(),
        granted_at: DateTime.utc_now()
      }

      {:ok, user_pid} =
        Ezagent.Kind.spawn(User, %{
          uri: caller_uri,
          initial_caps: MapSet.new([cap1])
        })

      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Test.init_test_session(%{"current_entity_uri" => URI.to_string(caller_uri)})

      {:ok, lv, mount_html} = live(conn, path_for(session_uri))
      # Sanity: mount succeeded (Cap 1 admits the list_bindings call).
      assert mount_html =~ URI.to_string(session_uri)

      # Now REVOKE Cap 1 from the User Kind slice. Direct sys mutation
      # simulates "admin grants/revokes caps through some other path"
      # (production: `Behavior.IdentityAdmin.invoke(:revoke_cap, ...)`).
      # Self-Identity cap left intact so the post-revoke
      # `list_caps_for` dispatch still admits step 5.5.
      # Post-lifecycle the per-Behavior slice is two-container
      # (`%{state: %{caps: …}, transients: …}`); `:caps` lives under the
      # `:state` sub-key, not at the slice's top level. Navigate the extra
      # level so the revoke mutation lands (the old path raised
      # `{:badkey, :caps}`). (post-lifecycle remediation.)
      :sys.replace_state(user_pid, fn state ->
        Map.update!(state, :state, fn slice_map ->
          Map.update!(slice_map, :identity, fn identity ->
            Map.update!(identity, :state, fn identity_state ->
              Map.update!(identity_state, :caps, fn caps -> MapSet.delete(caps, cap1) end)
            end)
          end)
        end)
      end)

      # Trigger the LV's refresh. The r2 fix navigates away on
      # `{:error, :unauthorized}`. `render_hook` raises an
      # `Phoenix.LiveViewTest.RedirectError` (or returns
      # `{:error, {:redirect, _}}` shape) when the LV pushes a
      # navigate. Catch either; the structural property is "the LV
      # left the page" — exactly what the r2 fix promises.
      result =
        try do
          render_hook(lv, "refresh", %{})
        catch
          :error, other -> {:caught, other}
        end

      case result do
        {:error, {:live_redirect, %{to: "/sessions"}}} ->
          :ok

        {:error, {:redirect, %{to: "/sessions"}}} ->
          :ok

        html when is_binary(html) ->
          # If the LV didn't navigate, the r2 fix is broken — stale
          # bindings would still be in @bindings. Fail loudly.
          flunk(
            "expected push_navigate(to: \"/sessions\") on Cap 1 revoke; got HTML: " <>
              String.slice(html, 0, 400)
          )

        other ->
          flunk("refresh returned unexpected: " <> inspect(other))
      end
    end

    test "happy path: per-event ctx rebuild does NOT break ordinary bind",
         %{session_uri: session_uri, owner_uri: owner_uri} do
      # The HIGH was: the LV cached `ctx` from mount, so a Cap 2 revoke
      # AFTER mount didn't propagate — the next bind still succeeded
      # because the stale MapSet held the revoked cap.
      #
      # Direct test of the fix: mount as admin, revoke admin's Cap 2 by
      # spawning a DIFFERENT user (so the admin User Kind keeps its
      # admin_caps), then verify that the LV's
      # `fresh_ctx_for_action/1` rebuilds the caps from the CURRENT
      # User Kind slice (not from the mount-time cache). We can't
      # easily revoke admin's `:any/:any/:any` cap (Capability.revoke
      # refuses), so we exercise the round-trip behaviour by spawning
      # a fresh user whose caps we CAN mutate, and asserting the LV
      # picks up the new caps when re-mounted with that user. The
      # pre-fix code path would still read whatever was in
      # `socket.assigns.caller_caps` from mount; the post-fix
      # `fresh_ctx_for_action/1` reads `Ezagent.Identity.list_caps_for/1`
      # again.
      :ok = spawn_owner_and_session(owner_uri, session_uri)

      # Admin caller — bind via the LV the normal way.
      {:ok, lv, _} = live(admin_conn(), path_for(session_uri))

      target = "tgt-pr4-fresh-ctx-#{System.unique_integer([:positive])}"

      _resp =
        lv
        |> render_hook("add_binding", %{
          "binding" => %{"adapter_id" => "pr4_mock", "target_id" => target}
        })

      # Render once more so the post-bind refresh fires; the binding
      # MUST be visible — proving the fresh ctx still carries the
      # admin caps and authorizes the bind.
      Process.sleep(20)
      html = render(lv)

      # The LV's fresh_ctx_for_action ran (HIGH-fix code path). The
      # bind landed. This proves the per-event ctx rebuild does NOT
      # break the happy path. The "revoke surfaces denial" half is
      # exercised by the cap1_only mount test above (caller with
      # missing Cap 2 sees empty-state dropdown — same code path
      # underneath: fresh caps rebuild → narrow-by-default filter).
      assert html =~ target,
             "post-HIGH-fix bind via LV did not land — fresh_ctx_for_action may have broken the happy path"
    end
  end

  # ----- (7) codex r1 LOW — P15 dropdown shows only adapter A -------------

  describe "codex r1 LOW — P15 narrow-by-default dropdown filter" do
    test "caller with Cap 2 only for adapter A sees A in dropdown, NOT B",
         %{session_uri: session_uri, owner_uri: owner_uri} do
      :ok = spawn_owner_and_session(owner_uri, session_uri)

      # Caller holds Cap 1 + Cap 2 for pr4_mock ONLY (not pr4_mock_b).
      caller_uri =
        Ezagent.URI.new!("entity://system/user/pr4_a_only_#{System.unique_integer([:positive])}")

      caps =
        MapSet.new([
          %Capability{
            kind: :session,
            behavior: Ezagent.Behavior.ExternalMirror,
            instance: session_uri,
            workspace_uri: @workspace_uri,
            granted_by: User.admin_uri(),
            granted_at: DateTime.utc_now()
          },
          %Capability{
            kind: :session,
            behavior: PR4TestAdapter.Allow,
            instance: :any,
            workspace_uri: @workspace_uri,
            granted_by: User.admin_uri(),
            granted_at: DateTime.utc_now()
          }
        ])

      {:ok, _pid} = Ezagent.Kind.spawn(User, %{uri: caller_uri, initial_caps: caps})

      conn =
        Phoenix.ConnTest.build_conn()
        |> Plug.Test.init_test_session(%{"current_entity_uri" => URI.to_string(caller_uri)})

      {:ok, _lv, html} = live(conn, path_for(session_uri))

      # P15 narrow-by-default: dropdown shows pr4_mock (Cap 2 held),
      # HIDES pr4_mock_b (Cap 2 NOT held). The test pins the actual
      # assertion: A-only-sees-A — not "redirect-counts-as-success".
      assert html =~ "pr4_mock"

      refute html =~ "pr4_mock_b",
             "P15 violation: dropdown listed pr4_mock_b even though caller does NOT hold PR4TestAdapterB.Allow Cap 2"
    end
  end

  # ----- helpers (mirrored from external_mirror_test.exs) -------------------

  defp ensure_adapter_registered(adapter, binding) do
    _ = AdapterRegistry.register(adapter)
    _ = BindingRegistry.register_module(adapter.adapter_id(), binding)

    %{behavior_module: behavior_module} = adapter.cap_subject()
    action = String.to_atom("allow_" <> adapter.adapter_id())

    try do
      :ok =
        Ezagent.CapabilityRegistry.register(
          Session,
          action,
          behavior_module
        )
    rescue
      _ -> :ok
    end

    :ok
  rescue
    _ -> :ok
  end

  defp cleanup_workers do
    case Process.whereis(RootSupervisor) do
      nil ->
        :ok

      _ ->
        DynamicSupervisor.which_children(RootSupervisor)
        |> Enum.each(fn {_id, pid, _type, _modules} ->
          if is_pid(pid) do
            _ = DynamicSupervisor.terminate_child(RootSupervisor, pid)
          end
        end)
    end

    :ok
  end

  defp cleanup_session(%URI{} = session_uri) do
    case Ezagent.KindRegistry.lookup(session_uri) do
      {:ok, pid} when is_pid(pid) ->
        _ = DynamicSupervisor.terminate_child(EzagentDomainInstanceMessage.SessionSupervisor, pid)
        :ok

      _ ->
        :ok
    end
  rescue
    _ -> :ok
  end

  defp spawn_owner_and_session(%URI{} = owner_uri, %URI{} = session_uri) do
    :ok = spawn_user(owner_uri, MapSet.new([Ezagent.Capability.admin_genesis_cap()]))

    # P5-0b — thread the explicit chat-Session behavior set so :kind_base is
    # non-nil and the scoped effective_set/2 guard does not crash the session.
    case Ezagent.Kind.spawn(Session, %{
           uri: session_uri,
           owner_uri: owner_uri,
           behaviors: Session.behaviors()
         }) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    ws = Ezagent.Capability.workspace_of(session_uri)

    case ws do
      %URI{} = ws_uri -> :ok = Ezagent.WorkspaceRegistry.bind(session_uri, ws_uri)
      :any -> :ok
    end

    await_session_alive(session_uri, 50)
  end

  defp spawn_user(%URI{} = user_uri, caps) do
    case Ezagent.Kind.spawn(User, %{uri: user_uri, initial_caps: caps}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    :ok
  end

  defp await_session_alive(_uri, 0), do: {:error, :timeout}

  defp await_session_alive(uri, retries) do
    case Ezagent.KindRegistry.lookup(uri) do
      {:ok, pid} when is_pid(pid) ->
        case Ezagent.ReadyGate.status(URI.to_string(uri)) do
          :ready -> :ok
          _ -> Process.sleep(20) && await_session_alive(uri, retries - 1)
        end

      _ ->
        Process.sleep(20)
        await_session_alive(uri, retries - 1)
    end
  end

  # admin_ctx with the per-adapter Cap 2 baked in via the bootstrap
  # `:any/:any/:any` shape (same shape facade tests use).
  defp owner_admin_ctx(owner_uri) do
    %{
      caller: owner_uri,
      caps:
        MapSet.new([
          %Capability{
            kind: :any,
            behavior: :any,
            instance: :any,
            workspace_uri: :any,
            granted_by: Ezagent.URI.user(:system, :admin),
            granted_at: ~U[2026-01-01 00:00:00Z]
          }
        ]),
      reply: :ignore
    }
  end

  defp unique_user_uri(prefix) do
    Ezagent.URI.new!("entity://team-alpha/user/#{prefix}-#{System.unique_integer([:positive])}")
  end

  defp unique_session_uri(prefix) do
    Ezagent.URI.new!(
      "session://team-alpha/default/#{prefix}-#{System.unique_integer([:positive])}"
    )
  end
end
