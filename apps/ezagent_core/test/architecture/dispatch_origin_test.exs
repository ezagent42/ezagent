defmodule Ezagent.Architecture.DispatchOriginTest do
  use ExUnit.Case, async: true

  alias Ezagent.{Capability, Cmd, Invocation}
  alias Ezagent.DispatchOrigin.Gate
  alias Ezagent.Test.{TestBehavior, TestKind}

  setup do
    uri = Ezagent.URI.new!("entity://team-alpha/agent/test_origin-gate")
    target = Ezagent.URI.new!("#{URI.to_string(uri)}?action=test.noop")
    presenter = Ezagent.URI.new!("entity://team-alpha/user/alice")
    {:ok, uri: uri, target: target, presenter: presenter}
  end

  test "unstamped invocation is rejected before behavior lookup", context do
    invocation = %Invocation{
      target: context.target,
      mode: :call,
      args: %{msg: "blocked"},
      ctx: %{caller: context.presenter, caps: MapSet.new(), reply: :ignore},
      origin: nil
    }

    assert {:error, :unstamped_origin} =
             Ezagent.Kind.Runtime.handle_dispatch(invocation, %{}, TestKind, context.uri)

    assert {:error, :unstamped_origin} = Invocation.dispatch(invocation)
  end

  test "external constructor overwrites request caller and rejects a stolen cap", context do
    victim = Ezagent.URI.new!("entity://team-alpha/user/bob")

    stolen = %Capability{
      kind: :test,
      behavior: TestBehavior,
      action: :noop,
      instance: context.uri,
      workspace_uri: Ezagent.URI.new!("workspace://team-alpha"),
      granted_by: victim,
      granted_at: DateTime.utc_now(),
      grantee_uri: victim,
      key_id: "stolen",
      signature: <<1>>
    }

    cmd =
      Cmd.authenticated_external(
        context.uri,
        :noop,
        %{msg: "blocked"},
        context.presenter,
        %{caller: victim, caps: MapSet.new([stolen]), reply: :ignore}
      )

    assert cmd.origin == :authenticated_external
    assert cmd.ctx.caller == context.presenter
    assert cmd.ctx.authenticated_principal == context.presenter

    invocation = %Invocation{
      target: context.target,
      mode: :call,
      args: cmd.args,
      ctx: cmd.ctx,
      origin: cmd.origin
    }

    assert {:error, :presenter_mismatch} =
             Ezagent.Kind.Runtime.handle_dispatch(invocation, %{}, TestKind, context.uri)
  end

  test "external provenance does not infer the authenticated principal from caller", context do
    invocation = %Invocation{
      target: context.target,
      mode: :call,
      args: %{},
      ctx: %{caller: context.presenter, caps: MapSet.new(), reply: :ignore},
      origin: :authenticated_external
    }

    assert {:error, :unauthenticated_presenter} =
             Ezagent.Kind.Runtime.handle_dispatch(invocation, %{}, TestKind, context.uri)
  end

  test "ingress source gate enumerates dispatches and constructors and reds on mutation" do
    root = Path.expand("../../../..", __DIR__)
    paths = Path.wildcard(Path.join(root, "apps/*/lib/**/*.ex"))
    inventory = Gate.inventory(paths)

    findings =
      Enum.flat_map(paths, fn path ->
        path
        |> File.read!()
        |> Gate.check_source(path)
      end)

    assert inventory.dispatches > 0
    assert inventory.constructors > 0
    assert findings == [], "unstamped product envelope constructors: #{inspect(findings)}"

    mutation = """
    def bad(target) do
      Ezagent.Invocation.dispatch(%Ezagent.Invocation{
        target: target, mode: :call, args: %{}, ctx: %{}, origin: nil
      })
    end
    """

    assert [{"mutation.ex", _, :unstamped_origin}] = Gate.check_source(mutation, "mutation.ex")
  end

  test "the source gate inventories the resolver seam as a dispatch source (V5 A1b)" do
    root = Path.expand("../../../..", __DIR__)
    resolver = Path.join(root, "apps/ezagent_actor/lib/ezagent/runtime/resolver.ex")

    # The seam's envelope constructor takes the origin from the CALLER (a
    # runtime value) — the gate knows the file as a dynamic-origin site and
    # does NOT red it.
    assert [] = Gate.check_source(File.read!(resolver), resolver)

    # `Resolver.dispatch/4` + raw `Resolver.call/3` count as dispatch
    # sources in the inventory (alongside Router.dispatch / Invocation.dispatch).
    fixture =
      Path.join(
        System.tmp_dir!(),
        "dispatch_origin_gate_fixture_#{System.unique_integer([:positive])}.ex"
      )

    File.write!(fixture, ~S"""
    Resolver.dispatch(uri, :ping, %{}, %{origin: :trusted_internal})
    Resolver.call(key, :msg)
    """)

    on_exit(fn -> File.rm(fixture) end)

    inventory = Gate.inventory([fixture])
    assert inventory.dispatches == 2
    assert inventory.constructors == 0
  end

  test "Feishu transports pass provenance into the shared dispatcher" do
    root = Path.expand("../../../..", __DIR__)

    webhook =
      File.read!(
        Path.join(
          root,
          "apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/webhook_plug.ex"
        )
      )

    websocket =
      File.read!(
        Path.join(root, "apps/ezagent_plugin_feishu/lib/ezagent/plugin_feishu/ws_client.ex")
      )

    assert webhook =~ "origin: nil"
    assert websocket =~ "origin: :authenticated_external"
  end
end
