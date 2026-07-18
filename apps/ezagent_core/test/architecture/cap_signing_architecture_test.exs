defmodule Ezagent.Architecture.CapSigningArchitectureTest do
  @moduledoc """
  §10 Path-A architecture ratchets for per-Kind capability signing.

  These static checks catch accidental or review-missed boundary expansion;
  the semantic guarantees remain owned by the paired runtime and §F tests.
  Malicious code already admitted into the BEAM is out of scope.
  """

  use EzagentCore.DataCase, async: false

  alias Ezagent.Cap.Verifier
  alias Ezagent.{Capability, Invocation}
  alias Ezagent.Test.{TestBehavior, TestKind}

  @root Path.expand("../../../..", __DIR__)
  @allowed_introspection MapSet.new([
                           "apps/ezagent_domain_python/lib/ezagent/domain/python/server.ex",
                           "apps/ezagent_domain_pty/lib/ezagent_domain_pty/server.ex"
                         ])

  test "the central verifier decision dominates an executed handler" do
    uri = unique_uri("dominance")
    presenter = Ezagent.URI.new!("entity://team-alpha/user/dominance-presenter")
    target = Ezagent.URI.with_action(uri, :test, :noop)

    :ok = Ezagent.BehaviorRegistry.register(TestKind, :noop, TestBehavior)
    assert {:ok, pid} = Ezagent.Kind.Server.start_link({TestKind, %{uri: uri}})
    assert :ok = await_ready(uri)

    requested = action_cap(uri)
    assert {:ok, signed} = Ezagent.Cap.issue({:admin, admin()}, presenter, requested)

    handler_id = "cap-signing-dominance-#{System.unique_integer([:positive])}"
    test_pid = self()

    :ok =
      :telemetry.attach_many(
        handler_id,
        [[:ezagent, :cap, :verify, :accepted], [:ezagent, :invoke, :stop]],
        fn event, _measurements, metadata, _config ->
          send(test_pid, {:cap_signing_event, event, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    invocation = %Invocation{
      target: target,
      mode: :call,
      args: %{msg: "dominated"},
      ctx: %{caller: presenter, caps: MapSet.new([signed]), reply: :ignore},
      origin: :authenticated_external
    }

    assert {:ok, %{echoed: "dominated"}} =
             GenServer.call(pid, {:ezagent_dispatch, invocation})

    assert_receive {:cap_signing_event, [:ezagent, :cap, :verify, :accepted], verify_meta}
    assert verify_meta.target == target
    assert verify_meta.action == :noop

    assert_receive {:cap_signing_event, [:ezagent, :invoke, :stop], invoke_meta}
    assert invoke_meta.target == target
    assert invoke_meta.action == :noop
    refute_receive {:cap_signing_event, _, _}
  end

  test "runtime has one handler route and its verifier precedes invocation" do
    source = File.read!(path("apps/ezagent_core/lib/ezagent/kind/runtime.ex"))

    assert occurrences(source, "invoke_behavior(") == 2,
           "invoke_behavior must have exactly one call site plus its definition"

    {verify_offset, _} = :binary.match(source, "Ezagent.Cap.Verifier.authorize(")
    {invoke_offset, _} = :binary.match(source, "invoke_behavior(")
    assert verify_offset < invoke_offset

    server = File.read!(path("apps/ezagent_core/lib/ezagent/kind/server.ex"))
    assert occurrences(server, "Ezagent.Kind.Runtime.handle_dispatch(") == 2
  end

  test "the interim non-cap class is closed and exact" do
    assert Verifier.non_cap_actions() == %{
             Ezagent.ActionSet.Identity => MapSet.new([:cascade_notify_managers]),
             Ezagent.ActionSet.IdentityAdmin =>
               MapSet.new([
                 :absorb_cap,
                 :persist_caps,
                 :store_cap,
                 :remove_cap,
                 :sync_recipe_binding
               ]),
             Ezagent.ActionSet.Agent.Receive => MapSet.new([:receive]),
             Ezagent.ActionSet.User.Receive => MapSet.new([:receive]),
             Ezagent.ActionSet.SocialwarePublisherRead => MapSet.new([:snapshot, :history]),
             Ezagent.ActionSet.Session =>
               MapSet.new([
                 :approve_admission,
                 :deny_admission,
                 :withdraw_admission,
                 :composition_consent
               ])
           }

    refute Ezagent.Kind.default_holds_cap?(:vm_internal, action_cap(unique_uri("vm")))
  end

  test "legacy bypass and dual-read paths are absent from product code" do
    offenders =
      for file <- product_sources(),
          token <- [
            "authz_check",
            "cap_issued",
            "authorization_rule",
            "require_signature",
            "verify_for",
            "sign_artifact",
            "cap_signing_backfill"
          ],
          File.read!(file) =~ token,
          do: {relative(file), token}

    assert offenders == []

    refute File.exists?(
             path("apps/ezagent_domain_identity/lib/ezagent/identity/cap_signing_backfill.ex")
           )

    refute File.exists?(
             path("apps/ezagent_domain_identity/lib/mix/tasks/ezagent.cap.backfill.ex")
           )

    ambient_admin_calls =
      product_sources()
      |> Enum.reject(&(relative(&1) == "apps/ezagent_core/lib/ezagent/capability.ex"))
      |> Enum.filter(&(File.read!(&1) =~ "admin_genesis_cap("))
      |> Enum.map(&relative/1)

    assert ambient_admin_calls == []
  end

  test "signing, key access, and Kind introspection remain framework-confined" do
    domain_or_plugin =
      product_sources()
      |> Enum.filter(fn file ->
        rel = relative(file)
        String.contains?(rel, "/ezagent_domain_") or String.contains?(rel, "/ezagent_plugin_")
      end)

    signing_offenders =
      domain_or_plugin
      |> Enum.filter(fn file ->
        source = File.read!(file)

        Enum.any?(
          [
            "Ezagent.Cap.Signing",
            "Cap.Signing",
            "Authority.sign(",
            "Authority.verify(",
            "private_key"
          ],
          &String.contains?(source, &1)
        )
      end)
      |> Enum.map(&relative/1)

    assert signing_offenders == []

    introspection_offenders =
      domain_or_plugin
      |> Enum.reject(&MapSet.member?(@allowed_introspection, relative(&1)))
      |> Enum.filter(&privileged_introspection?/1)
      |> Enum.map(&relative/1)

    assert introspection_offenders == [],
           "Kind process introspection escaped the framework:\n" <>
             Enum.join(introspection_offenders, "\n")
  end

  test "post-verifier issuance and target verification have singular call sites" do
    issue_callers = source_callers("Authority.issue_current(")
    assert issue_callers == ["apps/ezagent_core/lib/ezagent/cap/grant.ex"]

    verify_callers = source_callers("Authority.verify_current(")
    assert verify_callers == ["apps/ezagent_core/lib/ezagent/cap/verifier.ex"]

    signing_sites =
      product_sources()
      |> Enum.filter(&(File.read!(&1) =~ "Authority.sign("))
      |> Enum.map(&relative/1)

    assert signing_sites == ["apps/ezagent_core/lib/ezagent/cap/grant.ex"]
  end

  defp source_callers(needle) do
    product_sources()
    |> Enum.filter(&(File.read!(&1) =~ needle))
    |> Enum.map(&relative/1)
  end

  defp privileged_introspection?(file) do
    with {:ok, ast} <- file |> File.read!() |> Code.string_to_quoted() do
      {_ast, found?} =
        Macro.prewalk(ast, false, fn
          {{:., _, [module_ast, function]}, _, _args} = node, found ->
            {node, found or privileged_call?(module_ast, function)}

          node, found ->
            {node, found}
        end)

      found?
    else
      _ -> true
    end
  end

  defp privileged_call?(:sys, function),
    do: function in [:get_state, :replace_state, :get_status]

  defp privileged_call?(:erlang, :process_info), do: true
  defp privileged_call?(:erlang, :trace), do: true
  defp privileged_call?(:dbg, _function), do: true

  defp privileged_call?({:__aliases__, _, [:Process]}, :info), do: true
  defp privileged_call?(_module, _function), do: false

  defp product_sources do
    path("apps/*/lib/**/*.ex") |> Path.wildcard() |> Enum.sort()
  end

  defp path(relative), do: Path.join(@root, relative)
  defp relative(file), do: Path.relative_to(file, @root)

  defp occurrences(source, needle),
    do: max(length(String.split(source, needle)) - 1, 0)

  defp action_cap(uri) do
    Capability.cap(
      :test,
      TestBehavior,
      :noop,
      Ezagent.URI.instance(uri),
      Capability.workspace_of(uri)
    )
  end

  defp unique_uri(suffix) do
    Ezagent.URI.new!(
      "entity://team-alpha/agent/test_arch-#{suffix}-#{System.unique_integer([:positive])}"
    )
  end

  defp admin, do: Ezagent.URI.user(:system, :admin)

  defp await_ready(uri), do: await_ready(uri, System.monotonic_time(:millisecond) + 1_000)

  defp await_ready(uri, deadline) do
    case Ezagent.ReadyGate.status(uri) do
      :ready ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, :timeout}
        else
          Process.sleep(5)
          await_ready(uri, deadline)
        end
    end
  end
end
