defmodule EzagentDomainGit.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    with {:ok, _limits} <- Ezagent.DomainGit.ChangeLimits.current() do
      Supervisor.start_link([], strategy: :one_for_one, name: __MODULE__)
    end
  end
end
