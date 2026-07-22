defmodule Ezagent.Cap.TargetArtifactValidator do
  @moduledoc false

  @doc false
  @spec validate(Ezagent.Capability.t(), URI.t()) ::
          :ok | {:error, :invalid_cap_signature}
  def validate(%Ezagent.Capability{} = artifact, %URI{} = receiver) do
    with {:ok, target} <- Ezagent.Cap.Authority.target_uri(artifact) do
      case Ezagent.KindRegistry.lookup(target) do
        {:ok, pid} ->
          validate_live(pid, artifact, receiver)

        :error ->
          validate_cold(target, artifact, receiver)
      end
    else
      _reason -> {:error, :invalid_cap_signature}
    end
  end

  defp validate_live(pid, artifact, receiver) do
    GenServer.call(pid, {:ezagent_validate_cap_artifact, artifact, receiver})
  catch
    :exit, _reason -> {:error, :invalid_cap_signature}
  end

  defp validate_cold(target, artifact, receiver) do
    if Ezagent.Cap.Authority.verify_durable_current(target, artifact, receiver) do
      :ok
    else
      {:error, :invalid_cap_signature}
    end
  end
end
