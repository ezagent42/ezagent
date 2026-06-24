defmodule Ezagent.WorkspacePlacement.LocalResolver do
  @moduledoc """
  Default resolver for the current single-runtime deployment model.
  """

  @behaviour Ezagent.WorkspacePlacement

  @impl true
  def owner_of(%URI{scheme: "workspace"}) do
    {:ok, Ezagent.RuntimeIdentity.current()}
  end
end
