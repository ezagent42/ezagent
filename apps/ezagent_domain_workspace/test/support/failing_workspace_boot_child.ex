defmodule EzagentDomainWorkspace.TestSupport.FailingBootChild do
  @moduledoc false

  use GenServer

  def start_link(_opts), do: {:error, :injected_workspace_boot_failure}

  @impl true
  def init(state), do: {:ok, state}
end
