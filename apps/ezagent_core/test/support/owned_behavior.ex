defmodule Ezagent.TestSupport.OwnedBehavior do
  @moduledoc """
  Test-only Behavior implementing `data_owner/1` against a synthetic
  Kind. PR-OWN-1 acceptance test uses this to assert
  `CapabilityRegistry.default_grants_from_data_owner/2` returns the
  expected `[{grantee_uri, %Capability{}}]` tuple list.

  Returns the target_uri as its OWN owner so tests can assert:
  "spawning instance X grants the X→X data-owner cap to X". A real
  Behavior would lookup the owning entity (e.g.
  `Session.owner(target_uri)`).
  """
  @behaviour Ezagent.Behavior

  @impl true
  def actions, do: [:read, :write]

  @impl true
  def state_slice, do: :owned_behavior

  @impl true
  def init_slice(_args), do: %{}

  @impl true
  def invoke(_action, slice, _args, _ctx), do: {:ok, slice}

  @impl true
  def cap_subjects do
    [
      {:read, "owned behavior — read"},
      {:write, "owned behavior — write"}
    ]
  end

  @impl true
  def interface do
    %{
      read: %{description: "owned behavior — read", args: %{}},
      write: %{description: "owned behavior — write", args: %{}}
    }
  end

  @impl true
  def data_owner(%URI{} = target_uri), do: target_uri
  def data_owner(_), do: :no_owner
end

defmodule Ezagent.TestSupport.OwnedCapOnlyBehavior do
  @moduledoc """
  Test-only cap-only Behavior (`dispatchable?: false`) implementing
  `data_owner/1`. PR-OWN-1 round-5 regression test uses this to
  assert the default-grant helper enumerates CAP-ONLY Behaviors via
  `subjects_for_kind/1` — not the wrong abstraction that round-1
  used (`BehaviorRegistry.behaviors_for/1` skips cap-only).
  """
  @behaviour Ezagent.Behavior

  @impl true
  def actions, do: [:subscribe]

  @impl true
  def state_slice, do: :owned_cap_only

  @impl true
  def init_slice(_args), do: %{}

  @impl true
  def invoke(_action, slice, _args, _ctx), do: {:ok, slice}

  @impl true
  def cap_subjects, do: [{:subscribe, "owned cap-only — subscribe gate"}]

  @impl true
  def interface, do: %{subscribe: %{description: "subscribe gate", args: %{}}}

  @impl true
  def dispatchable?, do: false

  @impl true
  def data_owner(%URI{} = target_uri), do: target_uri
  def data_owner(_), do: :no_owner
end

defmodule Ezagent.TestSupport.OwnedKind do
  @moduledoc """
  Synthetic Kind for PR-OWN-1 acceptance tests. NOT a real
  `Ezagent.Kind` — bare module exposing only `type_name/0` so
  `default_grants_from_data_owner/2` can synthesize a cap.
  """
  def type_name, do: :owned_test_kind
end
