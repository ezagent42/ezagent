defmodule Ezagent.ExternalMirror.TestSupport.MockPublishAdapter do
  @moduledoc """
  PR-EM-2 test support — Adapter for the Worker spawn / publish-flow
  tests.

  Behaviour: `event_to_payload/1` echoes the event verbatim inside
  `{:publish, %{event: event}}`. `target_ownership_check/2` always
  grants (Worker-flow tests don't exercise the bind facade — that's
  PR-EM-3).

  The matching Binding is
  `Ezagent.ExternalMirror.TestSupport.MockPublishBinding` —
  a stateful per-binding GenServer-shape that forwards published
  payloads to a test PID stored in `:persistent_term` (so the
  test process can `assert_receive {:published, payload, target_id}`
  without each test having to plumb its own pid through bind args).
  """

  @behaviour Ezagent.ExternalMirror.Adapter

  @impl true
  def adapter_id, do: "mock_publish"

  @impl true
  def display_name, do: "Mock Publish Adapter"

  @impl true
  def description, do: "Test-only adapter for PR-EM-2 Worker publish-flow tests."

  @impl true
  def binding_module, do: Ezagent.ExternalMirror.TestSupport.MockPublishBinding

  @impl true
  def cap_subject do
    %{
      behavior_module: Ezagent.ExternalMirror.TestSupport.MockPublishAdapter.Allow,
      description: "Test-only mock publish adapter-allow cap."
    }
  end

  @impl true
  def target_ownership_check(_caller, _target_id), do: :ok

  @impl true
  def event_to_payload(%Ezagent.Publisher.Event{} = event),
    do: {:publish, %{event: event, echoed_at: DateTime.utc_now()}}
end
