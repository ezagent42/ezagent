defmodule Ezagent.DomainGit.TestSupport.FailingBootChild do
  def start_link(_opts), do: {:error, :later_child_failed}

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
  end
end
