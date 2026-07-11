defmodule Ezagent.Cap do
  @moduledoc """
  Capability artifact seam.

  Phase 3 keeps the artifact as an `Ezagent.Capability` struct. `issue/3`
  stamps accountable entity provenance without transferring the issuer's
  authority, and `verify/1` checks that provenance at trust boundaries. Phase 4
  can replace these bodies with signing and signature verification without
  changing callers.

  Grant authorization is deliberately still performed by the existing runtime
  and Identity handler in S1. It moves into `issue/3` in S2.
  """

  alias Ezagent.Capability

  @type artifact :: Capability.t()
  @type authorization ::
          {:held_by, URI.t()}
          | {:admin, URI.t()}
          | {:rule, atom(), URI.t()}
          | {:genesis, URI.t()}

  @doc """
  Stamp issuer provenance and produce a capability artifact.

  This is the mock issue seam. S2 adds the complete grantor-authorization
  predicates before an artifact can be returned.
  """
  @spec issue(authorization(), URI.t(), Capability.t()) ::
          {:ok, artifact()} | {:error, term()}
  def issue(authorization, %URI{}, %Capability{} = cap) do
    prepare_provenance(authorization, cap)
  end

  @doc """
  Return whether an artifact carries accountable entity provenance.

  The function is total so malformed or future-version artifacts fail closed.
  """
  @spec verify(term()) :: boolean()
  def verify(%Capability{granted_by: %URI{scheme: "entity"}}), do: true
  def verify(_artifact), do: false

  @doc false
  @spec prepare_provenance(authorization(), Capability.t()) ::
          {:ok, artifact()} | {:error, term()}
  def prepare_provenance(authorization, %Capability{} = cap) do
    granted_by = issuer(authorization)
    artifact = %{cap | granted_by: granted_by, granted_at: DateTime.utc_now()}

    if match?(%URI{scheme: "entity"}, granted_by) do
      {:ok, artifact}
    else
      {:error, {:granter_not_entity, granted_by}}
    end
  end

  defp issuer({:held_by, %URI{} = actor}), do: actor
  defp issuer({:admin, %URI{} = admin}), do: admin
  defp issuer({:rule, name, %URI{} = configurer}) when is_atom(name), do: configurer
  defp issuer({:genesis, %URI{} = granted_by}), do: granted_by
end
