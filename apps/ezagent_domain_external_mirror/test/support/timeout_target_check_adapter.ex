defmodule Ezagent.ExternalMirror.TestSupport.TimeoutAdapter.Allow do
  @moduledoc """
  PR-EM-3 — Per-adapter Allow Behavior for `TimeoutAdapter`.
  """
  @behaviour Ezagent.Behavior

  @impl true
  def actions, do: [:allow_em_timeout]

  @impl true
  def cap_subjects,
    do: [{:allow_em_timeout, "Authorize binding the timeout-test adapter on this session."}]

  @impl true
  def dispatchable?, do: false

  @impl true
  def state_slice, do: :external_adapter_em_timeout

  @impl true
  def init_slice(_args), do: %{}

  @impl true
  def invoke(_action, _slice, _args, _ctx) do
    raise "TimeoutAdapter.Allow is cap-only."
  end

  @impl true
  def interface, do: %{}

  @impl true
  def required_caps,
    do: %{allow_em_timeout: Ezagent.Capability.cap(:session, __MODULE__, :allow_em_timeout)}

  @impl true
  def data_owner(_), do: :any
end

defmodule Ezagent.ExternalMirror.TestSupport.TimeoutAdapter do
  @moduledoc """
  PR-EM-3 test support — adapter whose `target_ownership_check/2`
  either:

  - Sleeps for `target_id`-controlled milliseconds (tests timeout + non-blocking facade);
  - Returns `{:error, :not_a_member}` when `target_id` matches a denial fixture;
  - Returns `:ok` otherwise.

  `target_ownership_check_timeout/0` is overridden to 200ms so the
  facade-timeout test (test f) takes ~200ms not 5000ms.
  """

  @behaviour Ezagent.ExternalMirror.Adapter

  @impl true
  def adapter_id, do: "em_timeout"

  @impl true
  def display_name, do: "EM Timeout Adapter"

  @impl true
  def description, do: "PR-EM-3 test-only adapter — controlled target_ownership_check timing."

  @impl true
  def binding_module, do: Ezagent.ExternalMirror.TestSupport.TimeoutBinding

  @impl true
  def cap_subject do
    %{
      behavior_module: Ezagent.ExternalMirror.TestSupport.TimeoutAdapter.Allow,
      description: "Allow binding the timeout-test adapter on this session."
    }
  end

  @impl true
  def target_ownership_check_timeout, do: 200

  @impl true
  def target_ownership_check(_caller, target_id) when is_binary(target_id) do
    cond do
      String.starts_with?(target_id, "sleep:") ->
        [_, ms_str] = String.split(target_id, ":", parts: 2)
        ms = String.to_integer(ms_str)
        Process.sleep(ms)
        :ok

      String.starts_with?(target_id, "deny:") ->
        [_, reason] = String.split(target_id, ":", parts: 2)
        {:error, String.to_atom(reason)}

      true ->
        :ok
    end
  end

  def target_ownership_check(_caller, _target_id), do: :ok

  @impl true
  def event_to_payload(%Ezagent.Publisher.Event{} = event),
    do: {:publish, %{event: event}}
end

defmodule Ezagent.ExternalMirror.TestSupport.TimeoutBinding do
  @moduledoc """
  Paired Binding for `TimeoutAdapter`. Forwards publishes to an
  observer pid via :persistent_term (same pattern as MockPublishBinding).
  """

  @behaviour Ezagent.ExternalMirror.Binding

  @ptm_table __MODULE__

  @impl true
  def adapter_module, do: Ezagent.ExternalMirror.TestSupport.TimeoutAdapter

  @impl true
  def init({target_id, _adapter, opts}) do
    observer = Map.get(opts, :observer) || lookup_observer(target_id)
    {:ok, %{target_id: target_id, observer: observer, publish_count: 0}}
  end

  @impl true
  def publish(payload, state) do
    if is_pid(state.observer) and Process.alive?(state.observer) do
      send(state.observer, {:tb_published, payload, state.target_id})
    end

    {:ok, %{state | publish_count: state.publish_count + 1}}
  end

  @impl true
  def terminate(_reason, _state), do: :ok

  @spec register_observer(target_id :: term(), test_pid :: pid()) :: :ok
  def register_observer(target_id, test_pid) when is_pid(test_pid) do
    :persistent_term.put({@ptm_table, target_id}, test_pid)
    :ok
  end

  defp lookup_observer(target_id) do
    :persistent_term.get({@ptm_table, target_id}, nil)
  end
end
