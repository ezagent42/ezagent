defmodule Ezagent.Kind.InstanceSetUndeclaredTest do
  # RF-1 (role-foundation, generalized keystone): a recipe-loaded behavior that
  # the generic host Kind does NOT declare in `behaviors/0` must
  #   (A) materialize its slice (init_set/effective_set keep it),
  #   (B) dispatch via per-instance (static-first FALLBACK) resolution,
  #   (C) be UNREACHABLE on a sibling instance that did not load it, and
  #   (D) STILL be cap-gated by authz — presence in the set grants NO privilege.
  # The OLD per-instance-denial invariant (declared-but-scoped-out → denied) is
  # covered by Ezagent.Kind.InstanceSetDenialTest and must stay green.
  use EzagentCore.DataCase, async: false
  @moduletag :umbrella_only

  alias Ezagent.Kind.InstanceSetSupport.{SupersetSessionKind, UndeclaredProbe}
  alias Ezagent.Invocation

  setup do
    Code.ensure_loaded!(SupersetSessionKind)
    Code.ensure_loaded!(UndeclaredProbe)
    # NOTE: UndeclaredProbe is intentionally NOT registered in BehaviorRegistry
    # (no CapabilityRegistry.register). RF-1 must resolve it per-instance.
    refute match?(
             {:ok, _},
             Ezagent.BehaviorRegistry.lookup(SupersetSessionKind, :undeclared_poke)
           )

    Ezagent.LifecycleCase.ensure_gate_supervisor!()
    :persistent_term.put({UndeclaredProbe, :probe_pid}, self())

    on_exit(fn ->
      :persistent_term.erase({UndeclaredProbe, :probe_pid})
      sup = Ezagent.LifecycleCase.gate_supervisor()

      for {_, child_pid, _, _} <- DynamicSupervisor.which_children(sup), is_pid(child_pid) do
        _ = DynamicSupervisor.terminate_child(sup, child_pid)
      end
    end)

    :ok
  end

  defp admin_caps(uri, behavior, action) do
    cap =
      signed_fixture_cap!(
        uri,
        SupersetSessionKind.type_name(),
        behavior,
        action,
        Ezagent.Entity.User.admin_uri()
      )

    MapSet.new([cap])
  end

  defp with_probe, do: [Ezagent.ActionSet.Session, UndeclaredProbe, Ezagent.ActionSet.KindBase]

  test "(A) BLOCKER-1: an UNDECLARED recipe-loaded behavior materializes its slice (init_set/effective_set keep it)" do
    uri =
      Ezagent.URI.session(:system, :default, :"isu-slice-#{System.unique_integer([:positive])}")

    fresh =
      Ezagent.Kind.Snapshot.load_or_init(uri, SupersetSessionKind, %{behaviors: with_probe()})

    # The slice exists → its create/init_slice ran → not dropped by the ∩-declared filter.
    assert Map.has_key?(fresh, :undeclared_probe)
    assert UndeclaredProbe in Ezagent.Kind.BehaviorSet.effective_set(SupersetSessionKind, fresh)
  end

  test "(B) an UNDECLARED loaded behavior dispatches via per-instance (static-first fallback) resolution" do
    uri =
      Ezagent.URI.session(:system, :default, :"isu-disp-#{System.unique_integer([:positive])}")

    {:ok, _pid} = Ezagent.Kind.spawn(SupersetSessionKind, %{uri: uri, behaviors: with_probe()})

    target = Ezagent.URI.new!("#{URI.to_string(uri)}?action=undeclared_probe.undeclared_poke")

    Invocation.dispatch(%Invocation{
      origin: :trusted_internal,
      target: target,
      mode: :call,
      args: %{},
      ctx: %{
        caller: Ezagent.Entity.User.admin_uri(),
        caps: admin_caps(uri, UndeclaredProbe, :undeclared_poke),
        reply: :ignore
      }
    })

    assert_received {:undeclared_probe, :handled}
  end

  test "(C) a sibling instance that did NOT load it resolves :unknown_action (no crash, no shadow)" do
    uri = Ezagent.URI.session(:system, :default, :"isu-sib-#{System.unique_integer([:positive])}")
    chat_only = [Ezagent.ActionSet.Session, Ezagent.ActionSet.KindBase]
    {:ok, _pid} = Ezagent.Kind.spawn(SupersetSessionKind, %{uri: uri, behaviors: chat_only})

    target = Ezagent.URI.new!("#{URI.to_string(uri)}?action=undeclared_probe.undeclared_poke")

    result =
      Invocation.dispatch(%Invocation{
        origin: :trusted_internal,
        target: target,
        mode: :call,
        args: %{},
        ctx: %{
          caller: Ezagent.Entity.User.admin_uri(),
          caps: admin_caps(uri, UndeclaredProbe, :undeclared_poke),
          reply: :ignore
        }
      })

    assert {:error, {:unknown_action, :undeclared_poke}} = result
    refute_received {:undeclared_probe, :handled}
  end

  test "(D) P1-new: a loaded UNDECLARED behavior is STILL cap-gated — presence grants NO privilege" do
    uri =
      Ezagent.URI.session(:system, :default, :"isu-priv-#{System.unique_integer([:positive])}")

    {:ok, _pid} = Ezagent.Kind.spawn(SupersetSessionKind, %{uri: uri, behaviors: with_probe()})

    target = Ezagent.URI.new!("#{URI.to_string(uri)}?action=undeclared_probe.undeclared_poke")

    result =
      Invocation.dispatch(%Invocation{
        origin: :trusted_internal,
        target: target,
        mode: :call,
        args: %{},
        # nobody, empty caps — holds neither :undeclared_poke nor genesis.
        ctx: %{
          caller: Ezagent.URI.new!("entity://team-alpha/user/nobody"),
          caps: MapSet.new(),
          reply: :ignore
        }
      })

    assert {:error, :missing_cap} = result
    refute_received {:undeclared_probe, :handled}
  end
end
