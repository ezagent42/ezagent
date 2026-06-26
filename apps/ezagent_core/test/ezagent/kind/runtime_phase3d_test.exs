defmodule Ezagent.Kind.RuntimePhase3dTest do
  @moduledoc """
  Phase 3d runtime invariant gate (per memory
  `feedback_completion_requires_invariant_test`):

  Invariant #10 isn't truly tested by grep alone — a future refactor
  might keep `Capability.matches?` in the file but stop calling it
  from the dispatch path. This test exercises the actual dispatch
  with a denying ctx and asserts the deny manifests as
  `{:error, :unauthorized}` + `[:ezagent, :authz, :denied]` telemetry.

  If this test starts failing, the cap-deny gate has been bypassed
  somehow (stub revived, default cap silently injected, etc).
  """

  use EzagentCore.DataCase, async: false

  # #52 Mode-A: cross-tier suite — references sibling-app modules; resolves
  # only in the umbrella. Excluded standalone (`cd apps/ezagent_core && mix test`).
  @moduletag :umbrella_only
  alias Ezagent.Invocation

  setup do
    # Sandbox provided by EzagentCore.DataCase (#92).
    # Attach a telemetry handler for the duration of this test to capture
    # :authz events. Detach in on_exit.
    test_pid = self()
    handler_id = "phase3d-test-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler_id,
      [
        [:ezagent, :authz, :granted],
        [:ezagent, :authz, :denied]
      ],
      fn event, _measurements, meta, _config ->
        send(test_pid, {:authz_event, event, meta})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok
  end

  # A live, cap-gated `:call` target spawned in-test (decoupled from any
  # boot-seeded agent): a Session Kind's `session.send`. This file gates the
  # AUTHZ invariant (granted/denied telemetry + `:unauthorized`), NOT any
  # reply value — so the target need only be a cap-gated `:call` action.
  defp live_call_target do
    short = "phase3d_#{System.unique_integer([:positive])}"

    {:ok, session_uri, _meta} =
      EzagentDomainInstanceMessage.SessionCreator.create_session(
        short,
        Ezagent.Entity.User.admin_uri(),
        template_name: "default"
      )

    msg = Ezagent.Message.new(Ezagent.Entity.User.admin_uri(), %{text: "x", attachments: []})
    target = URI.new!("#{URI.to_string(session_uri)}?action=session.send")
    {target, msg}
  end

  test "dispatch with empty caps → {:error, :unauthorized} + :denied telemetry" do
    {target, msg} = live_call_target()

    inv = %Invocation{
      target: target,
      mode: :call,
      args: %{message: msg},
      ctx: %{
        caller: URI.new!("entity://team-alpha/user/nobody"),
        caps: MapSet.new(),
        reply: :ignore
      }
    }

    assert {:error, :unauthorized} = Invocation.dispatch(inv)

    # :denied telemetry fired
    assert_receive {:authz_event, [:ezagent, :authz, :denied], meta}, 500
    assert meta.target == target
    assert meta.action == :send
  end

  test "dispatch with admin caps → success + :granted telemetry" do
    {target, msg} = live_call_target()

    inv = %Invocation{
      target: target,
      mode: :call,
      args: %{message: msg},
      ctx: %{
        caller: Ezagent.Entity.User.admin_uri(),
        caps: MapSet.new([Ezagent.Capability.admin_genesis_cap()]),
        reply: :ignore
      }
    }

    # Authz gate is what this file pins — the admin superset cap matches; the
    # inner result shape is not asserted (it is NOT :unauthorized).
    refute match?({:error, :unauthorized}, Invocation.dispatch(inv))

    assert_receive {:authz_event, [:ezagent, :authz, :granted], _meta}, 500
  end
end
