defmodule Ezagent.Entity.Agent.TemplateSpawn.BehaviorOverlay do
  @moduledoc false

  @doc false
  def mount(_workers, []), do: :ok

  def mount(workers, behaviors) when is_list(workers) and is_list(behaviors) do
    Enum.reduce_while(workers, :ok, fn worker_uri, :ok ->
      case mount_worker(worker_uri, behaviors) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def mount(_workers, overlay), do: {:error, {:invalid_behavior_overlay, overlay}}

  defp mount_worker(worker_uri, behaviors) do
    Enum.reduce_while(behaviors, :ok, fn behavior, :ok ->
      case Ezagent.Kind.mount(worker_uri, behavior, %{}) do
        :ok ->
          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, {:behavior_overlay_mount_failed, worker_uri, behavior, reason}}}
      end
    end)
  end
end
