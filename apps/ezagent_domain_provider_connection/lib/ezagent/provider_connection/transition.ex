defmodule Ezagent.ProviderConnection.Transition do
  @moduledoc "Closed legal transition graph for provider connections."
  @edges MapSet.new([
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
         ])
  @doc "Returns whether a provider connection may move directly between two statuses."
  @spec allowed?(atom(), atom()) :: boolean()
  def allowed?(from, to), do: MapSet.member?(@edges, {from, to})
end
