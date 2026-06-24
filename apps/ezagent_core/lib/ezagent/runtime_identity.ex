defmodule Ezagent.RuntimeIdentity do
  @moduledoc """
  Runtime identity used by workspace ownership gates.

  The identity is deployment/runtime metadata, not business domain state.
  Tests may override it through application env.
  """

  @doc """
  Returns the identity of the current runtime for placement comparisons.

  Production defaults to the BEAM node name. Tests may override the value
  through application env to simulate multiple runtimes without clustering.
  """
  @spec current() :: term()
  def current do
    case Application.get_env(:ezagent_core, __MODULE__, [])[:runtime_id] do
      nil -> node()
      runtime_id -> runtime_id
    end
  end
end
