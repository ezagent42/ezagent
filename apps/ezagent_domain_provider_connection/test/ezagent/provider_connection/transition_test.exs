defmodule Ezagent.ProviderConnection.TransitionTest do
  use ExUnit.Case, async: true
  alias Ezagent.ProviderConnection.Transition

  test "the legal transition graph is the exact frozen edge table" do
    edges = [
      {:pending_authorization, :active},
      {:active, :refresh_required},
      {:refresh_required, :refreshing},
      {:refreshing, :active},
      {:active, :degraded},
      {:refresh_required, :degraded},
      {:refreshing, :degraded},
      {:active, :expired},
      {:refresh_required, :expired},
      {:refreshing, :expired},
      {:degraded, :expired},
      {:active, :revoking},
      {:degraded, :revoking},
      {:expired, :revoking},
      {:revoking, :revoked},
      {:active, :disconnecting},
      {:degraded, :disconnecting},
      {:expired, :disconnecting},
      {:disconnecting, :disconnected}
    ]

    statuses = Ezagent.ProviderConnection.Types.statuses()
    actual = for from <- statuses, to <- statuses, Transition.allowed?(from, to), do: {from, to}

    assert MapSet.new(actual) == MapSet.new(edges)
    refute Transition.allowed?(:revoked, :active)
    refute Transition.allowed?(:disconnected, :pending_authorization)
  end
end
