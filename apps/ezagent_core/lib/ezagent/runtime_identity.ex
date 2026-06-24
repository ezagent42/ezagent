defmodule Ezagent.RuntimeIdentity do
  @moduledoc """
  Runtime identity used by workspace ownership gates.

  The identity is deployment/runtime metadata, not business domain state.
  Tests may override it through application env.
  """

  @spec current() :: term()
  def current do
    case Application.get_env(:ezagent_core, __MODULE__, [])[:runtime_id] do
      nil -> node()
      runtime_id -> runtime_id
    end
  end
end
