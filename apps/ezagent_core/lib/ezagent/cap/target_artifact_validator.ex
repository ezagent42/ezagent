defmodule Ezagent.Cap.TargetArtifactValidator do
  @moduledoc false

  @doc false
  @spec validate(Ezagent.Capability.t(), URI.t()) ::
          :ok | {:error, :invalid_cap_signature}
  def validate(%Ezagent.Capability{} = artifact, %URI{} = receiver) do
    with {:ok, target} <- Ezagent.Cap.Authority.target_uri(artifact) do
      # Delivery is URI-native (V5 A1c chunk2): the resolver resolves the
      # target URI to a pid INSIDE the seam and performs the call (default
      # 5_000 timeout, as before). The not-found/dead-target mapping is
      # preserved exactly: a KindRegistry miss fell through to the durable
      # cold validation; a mid-call exit mapped to :invalid_cap_signature.
      case Ezagent.Runtime.Resolver.call(
             target,
             {:ezagent_validate_cap_artifact, artifact, receiver}
           ) do
        {:ok, reply} -> reply
        {:error, :no_such_actor} -> validate_cold(target, artifact, receiver)
        {:error, _reason} -> {:error, :invalid_cap_signature}
      end
    else
      _reason -> {:error, :invalid_cap_signature}
    end
  end

  defp validate_cold(target, artifact, receiver) do
    if Ezagent.Cap.Authority.verify_durable_current(target, artifact, receiver) do
      :ok
    else
      {:error, :invalid_cap_signature}
    end
  end
end
