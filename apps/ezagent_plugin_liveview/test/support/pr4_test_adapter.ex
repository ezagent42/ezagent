defmodule EzagentPluginLiveview.PR4TestAdapter.Allow do
  @moduledoc """
  Per-adapter Allow Behavior for the PR-EM-4 admin LV test (mirrors
  `Ezagent.ExternalMirror.TestSupport.MockPublishAdapter.Allow` from
  the external_mirror domain's test/support but lives in this app's
  load path).

  Plugin-LV tests can't reach into `:ezagent_domain_external_mirror`'s
  `test/support` because each umbrella app's `elixirc_paths(:test)`
  is scoped to its own `test/support` — so the PR-EM-3 mocks are not
  loaded here. Defining a parallel mock keeps the PR-EM-4 test in a
  self-contained app.
  """
  @behaviour Ezagent.Behavior

  @impl true
  def actions, do: [:allow_pr4_mock]

  @impl true
  def cap_subjects,
    do: [{:allow_pr4_mock, "PR-EM-4 admin-LV test adapter allow cap."}]

  @impl true
  def dispatchable?, do: false

  @impl true
  def state_slice, do: :external_adapter_pr4_mock

  @impl true
  def init_slice(_args), do: %{}

  @impl true
  def invoke(_action, _slice, _args, _ctx) do
    raise "PR4TestAdapter.Allow is cap-only."
  end

  @impl true
  def interface, do: %{}

  @impl true
  def data_owner(_), do: :any
end

defmodule EzagentPluginLiveview.PR4TestAdapter do
  @moduledoc """
  Test-only adapter for the PR-EM-4 admin LV: pure stub, target check
  always succeeds, publish always succeeds. Mirrors the SPEC §2.2
  callback shape so `Ezagent.ExternalMirror.bind/4` exercises the full
  facade path (Check 2 cap + Check 3 target_ownership_check + nonce).

  Module name uses `pr4_mock` as adapter_id so it doesn't collide
  with the domain's `mock_publish` / `mock_em` adapter ids that other
  test trees register.
  """
  @behaviour Ezagent.ExternalMirror.Adapter

  @impl true
  def adapter_id, do: "pr4_mock"

  @impl true
  def display_name, do: "PR-4 Test Adapter"

  @impl true
  def description, do: "PR-EM-4 admin-LV test adapter (no I/O)."

  @impl true
  def binding_module, do: EzagentPluginLiveview.PR4TestBinding

  @impl true
  def cap_subject do
    %{
      behavior_module: EzagentPluginLiveview.PR4TestAdapter.Allow,
      description: "PR-EM-4 admin-LV test adapter allow cap."
    }
  end

  @impl true
  def target_ownership_check(_caller, _target_id), do: :ok

  @impl true
  def event_to_payload(%Ezagent.Publisher.Event{} = event),
    do: {:publish, %{echo: event}}
end

defmodule EzagentPluginLiveview.PR4TestBinding do
  @moduledoc """
  Paired binding for `EzagentPluginLiveview.PR4TestAdapter`. Pure
  no-op publish + terminate so the per-binding GenServer can spin up
  the Worker Kind on bind without external I/O.
  """
  @behaviour Ezagent.ExternalMirror.Binding

  @impl true
  def adapter_module, do: EzagentPluginLiveview.PR4TestAdapter

  @impl true
  def init({_target_id, _adapter, options}), do: {:ok, options}

  @impl true
  def publish(_payload, state), do: {:ok, state}

  @impl true
  def terminate(_reason, _state), do: :ok
end
