defmodule Ezagent.Cap.TargetArtifactValidator do
  @moduledoc false

  @doc false
  @spec validate(Ezagent.Capability.t(), URI.t()) ::
          :ok | {:error, :invalid_cap_signature}
  def validate(%Ezagent.Capability{} = artifact, %URI{} = receiver) do
    with {:ok, target} <- Ezagent.Cap.Authority.target_uri(artifact) do
      case Ezagent.KindRegistry.lookup(target) do
        {:ok, pid} ->
          GenServer.call(pid, {:ezagent_validate_cap_artifact, artifact, receiver})

        :error ->
          {:error, :invalid_cap_signature}
      end
    else
      _reason -> {:error, :invalid_cap_signature}
    end
  catch
    :exit, _reason -> {:error, :invalid_cap_signature}
  end
end
