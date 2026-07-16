defmodule EzagentDomainGit.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    with {:ok, _limits} <- Ezagent.DomainGit.ChangeLimits.current() do
      boot_opts = Application.get_env(:ezagent_domain_git, :boot_registration, [])
      later_children = Application.get_env(:ezagent_domain_git, :later_boot_children, [])

      with {:ok, supervisor} <-
             Supervisor.start_link(
               [
                 {Ezagent.DomainGit.AdapterRegistry, []},
                 {Ezagent.DomainGit.BootRegistration, boot_opts},
                 Ezagent.DomainGit.TaskAccessSupervisor
               ],
               strategy: :one_for_one,
               name: __MODULE__
             ) do
        start_later_children(supervisor, later_children)
      end
    end
  end

  defp start_later_children(supervisor, children) do
    Enum.reduce_while(children, {:ok, supervisor}, fn child, {:ok, ^supervisor} ->
      case Supervisor.start_child(supervisor, child) do
        {:ok, _pid} ->
          {:cont, {:ok, supervisor}}

        {:error, reason} ->
          :ok = Supervisor.terminate_child(supervisor, Ezagent.DomainGit.BootRegistration)
          :ok = Supervisor.stop(supervisor)
          {:halt, {:error, reason}}
      end
    end)
  end
end
