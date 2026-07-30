defmodule EzagentPluginFeishu.Integration.BootDispatchFeasibilityTest do
  @moduledoc """
  Production B-layer boot-dispatch acceptance evidence.

  Mission checklist (handoff §4 Phase 0):
  1. UserBinding actions are registered              — asserted directly.
  2. The seed row's Workspace Kind is startable/reachable at after_boot
     timing                                          — the workspace Kind
     is explicitly killed after being persisted, then only
     `Workspace.Loader.load_all/0` (the exact call `after_boot/0` makes
     first) brings it back — this is not test-setup residue.
  3. Canonical admin obtains a concrete target/action SIGNED capability
     — `ctx.caps` starts EMPTY; the passing dispatch proves the
     framework minted the cap, not the test.
  4. Synchronous dispatch returns the real handler result — asserted via
     the actual DB row (open_id/user_uri/bound_by), not a stubbed
     return.
  5. No direct handler, no raw storage, no empty-caps special case, no
     new system principal — the negative-path tests below prove the
     SAME dispatch is refused both without the admin-operator scope and
     for a non-admin caller, so the positive result is not a blanket
     bypass.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.{Cmd, Invocation, KindRegistry, Router}
  alias EzagentPluginFeishu.Behavior.UserBinding, as: UserBindingBehavior
  alias EzagentPluginFeishu.UserBinding, as: UB
  alias EzagentPluginFeishu.UserBindingSeed.DispatchAdapter

  @admin Ezagent.Entity.User.admin_uri()

  defp wait_until(fun, attempts \\ 100)
  defp wait_until(_fun, 0), do: flunk("wait_until: condition never became true")

  defp wait_until(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, attempts - 1)
    end
  end

  # Persist a workspace (so it is discoverable by `Workspace.Store.list_all/0`
  # exactly like a pre-existing tenant workspace at boot), then kill its live
  # Kind so nothing is running yet — mirroring true cold boot where only DB
  # rows exist until the Loader walks them.
  defp persisted_but_cold_workspace!(ws_name) do
    ws_uri = Ezagent.URI.new!("workspace://#{ws_name}")
    {:ok, _pid} = Ezagent.Workspace.create(ws_name)
    :ok = Ezagent.Kind.terminate(ws_uri)
    wait_until(fn -> KindRegistry.lookup(ws_uri) == :error end)
    ws_uri
  end

  defp bind_target(ws_name) do
    Ezagent.URI.new!("workspace://#{ws_name}?action=feishu_user_bindings.bind")
  end

  defp dispatch_bind(target, open_id, user_uri, caller, caps \\ MapSet.new()) do
    target
    |> Ezagent.URI.instance()
    |> Cmd.trusted_internal(
      :bind,
      %{open_id: open_id, user_uri: user_uri},
      caller,
      %{
        authenticated_principal: caller,
        caps: caps,
        reply: {:caller_inbox, self()},
        mode: :call
      }
    )
    |> Router.dispatch()
  end

  test "mission check 1: UserBinding actions are registered on Workspace Kind" do
    for action <- [:bind, :unbind, :list_feishu_bindings] do
      assert {:ok, %{behavior: UserBindingBehavior, kind: Ezagent.Entity.Workspace}} =
               Ezagent.CapabilityRegistry.lookup_subject(Ezagent.Entity.Workspace, action),
             "expected (Workspace, #{inspect(action)}) → UserBinding registered as a cap subject"
    end
  end

  test "mission checks 2-5: after Loader.load_all/0 (after_boot timing), canonical admin binds via real synchronous dispatch, empty ctx.caps" do
    ws_name = "feishu-boot-#{System.unique_integer([:positive])}"
    user_uri = Ezagent.URI.new!("entity://#{ws_name}/user/newcomer")
    open_id = "ou_boot_feasibility_#{System.unique_integer([:positive])}"

    ws_uri = persisted_but_cold_workspace!(ws_name)

    # Sanity: genuinely cold — nothing alive for this workspace yet.
    assert KindRegistry.lookup(ws_uri) == :error

    # The EXACT call `EzagentPluginFeishu.Application.after_boot/0` makes
    # FIRST, before seeding (application.ex:150).
    _ = Ezagent.Workspace.Loader.load_all()

    # Mission check 2: the seed row's Workspace Kind is now reachable.
    assert {:ok, _pid} = KindRegistry.lookup(ws_uri),
           "Workspace.Loader.load_all/0 did not bring the persisted workspace back " <>
             "up — the after_boot timing precondition for admin cap minting " <>
             "(Ezagent.KindRegistry.lookup/1 inside materialize_admin_action_cap/1) " <>
             "would fail, and Phase 0 cannot proceed on this seam."

    previous = Application.get_env(:ezagent_plugin_feishu, :seed_operator_uri)
    Application.put_env(:ezagent_plugin_feishu, :seed_operator_uri, URI.to_string(@admin))

    on_exit(fn ->
      if is_nil(previous) do
        Application.delete_env(:ezagent_plugin_feishu, :seed_operator_uri)
      else
        Application.put_env(:ezagent_plugin_feishu, :seed_operator_uri, previous)
      end
    end)

    # Mission check 3+4: the production adapter reads the runtime operator,
    # enters the reviewed process-local scope, and dispatches a Cmd. The
    # framework materializes the exact cap; the adapter constructs none.
    result = DispatchAdapter.bind(ws_uri, open_id, user_uri)

    assert {:ok, %{open_id: ^open_id, user_uri: bound_uri_str}} = result
    assert bound_uri_str == URI.to_string(user_uri)

    # Mission check 4 (real handler execution, not a stub): the durable row
    # exists with the REAL authenticated admin as bound_by.
    assert {:ok, resolved} = UB.resolve(open_id)
    assert URI.to_string(resolved) == URI.to_string(user_uri)

    row = EzagentCore.Repo.get(EzagentPluginFeishu.UserBinding, open_id)
    assert row.bound_by == URI.to_string(@admin)

    # The adapter is the importer boundary, so it must unwrap the Behavior's
    # `%{bindings: bindings}` result into the list shape consumed by preflight.
    assert {:ok, bindings} = DispatchAdapter.list_current(ws_uri)
    assert is_list(bindings)

    assert Enum.any?(bindings, fn binding ->
             binding.open_id == open_id and binding.user_uri == URI.to_string(user_uri)
           end)
  end

  test "mission check 5a: the SAME dispatch is refused OUTSIDE the admin-operator scope (no ambient bypass)" do
    ws_name = "feishu-boot-noscope-#{System.unique_integer([:positive])}"
    user_uri = Ezagent.URI.new!("entity://#{ws_name}/user/newcomer")
    open_id = "ou_boot_noscope_#{System.unique_integer([:positive])}"

    ws_uri = persisted_but_cold_workspace!(ws_name)
    _ = Ezagent.Workspace.Loader.load_all()
    assert {:ok, _pid} = KindRegistry.lookup(ws_uri)

    target = bind_target(ws_name)

    # Same caller URI, same empty caps, same target — but WITHOUT the
    # `with_admin_operator/2` process-local scope. `materialize_admin_action_cap/1`
    # requires `admin_operator_scope?/1` to hold, so no cap is minted here and
    # the dispatch must fail the ordinary CapBAC check.
    assert {:error, _reason} = dispatch_bind(target, open_id, user_uri, @admin)
    assert :error = UB.resolve(open_id)
  end

  test "mission check 5b: a non-admin caller inside with_admin_operator/2 does NOT get auto-minted caps" do
    ws_name = "feishu-boot-nonadmin-#{System.unique_integer([:positive])}"
    user_uri = Ezagent.URI.new!("entity://#{ws_name}/user/newcomer")
    open_id = "ou_boot_nonadmin_#{System.unique_integer([:positive])}"
    non_admin = Ezagent.URI.new!("entity://#{ws_name}/user/some-operator")

    ws_uri = persisted_but_cold_workspace!(ws_name)
    _ = Ezagent.Workspace.Loader.load_all()
    assert {:ok, _pid} = KindRegistry.lookup(ws_uri)

    target = bind_target(ws_name)

    # `canonical_admin?/1` requires the LITERAL admin URI. Wrapping a
    # non-admin caller in `with_admin_operator/2` must NOT mint a cap for
    # them — otherwise ANY caller could self-elevate by calling the
    # convenience wrapper.
    result =
      Invocation.with_admin_operator(non_admin, fn ->
        dispatch_bind(target, open_id, user_uri, non_admin)
      end)

    assert {:error, _reason} = result
    assert :error = UB.resolve(open_id)
  end
end
