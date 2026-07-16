defmodule EzagentDomainGit.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    with {:ok, _limits} <- Ezagent.DomainGit.ChangeLimits.current() do
      boot_opts = Application.get_env(:ezagent_domain_git, :boot_registration, [])

      task_access_child =
        Application.get_env(
          :ezagent_domain_git,
          :task_access_child,
          Ezagent.DomainGit.TaskAccessSupervisor
        )

      later_children = Application.get_env(:ezagent_domain_git, :later_boot_children, [])

      case Supervisor.start_link(
             [{Ezagent.DomainGit.AdapterRegistry, []}],
             strategy: :one_for_one,
             name: __MODULE__
           ) do
        {:ok, supervisor} ->
          start_registration(supervisor, boot_opts, [task_access_child | later_children])

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp start_registration(supervisor, boot_opts, post_registration_children) do
    case Supervisor.start_child(supervisor, {Ezagent.DomainGit.BootRegistration, boot_opts}) do
      {:ok, _registration} ->
        start_post_registration_children(supervisor, post_registration_children)

      {:error, _reason} = error ->
        :ok = Supervisor.stop(supervisor)
        error
    end
  end

  defp start_post_registration_children(supervisor, children) do
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
