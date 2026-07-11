defmodule Ezagent.Cap do
  @moduledoc """
  Capability artifact seam.

  Phase 3 keeps the artifact as an `Ezagent.Capability` struct. `issue/3`
  stamps accountable entity provenance without transferring the issuer's
  authority, and `verify/1` checks that provenance at trust boundaries. Phase 4
  can replace these bodies with signing and signature verification without
  changing callers.

  `issue/3` loads the issuer's held authority through the dependency-inverted
  durable loader and runs the complete grantor-authorization algorithm before
  returning an artifact. Downstream handlers only store issued artifacts.
  """

  alias Ezagent.{Capability, CapabilityRegistry}

  @type artifact :: Capability.t()
  @type authorization ::
          {:held_by, URI.t()}
          | {:admin, URI.t()}
          | {:rule, atom(), URI.t()}
          | {:genesis, URI.t()}

  @doc """
  Authorize the issuer, stamp issuer provenance, and produce an artifact.
  """
  @spec issue(authorization(), URI.t(), Capability.t()) ::
          {:ok, artifact()} | {:error, term()}
  def issue(authorization, %URI{}, %Capability{} = cap) do
    {caps, context} = authorization_context(authorization)

    with :ok <- CapabilityRegistry.authorize_grant(caps, cap, context) do
      prepare_provenance(authorization, cap)
    end
  end

  @doc """
  Return whether an artifact carries accountable entity provenance.

  The function is total so malformed or future-version artifacts fail closed.
  """
  @spec verify(term()) :: boolean()
  def verify(%Capability{granted_by: %URI{scheme: "entity"}}), do: true
  def verify(_artifact), do: false

  @doc """
  Return the verified subset of a capability collection as a `MapSet`.

  Load boundaries share this small adapter so Phase 4 still upgrades the one
  `verify/1` seam rather than duplicating collection handling across domains.
  Malformed containers and invalid artifacts fail closed as an empty/filtered
  set.
  """
  @spec verified_set(term()) :: MapSet.t(Capability.t())
  def verified_set(caps) when is_list(caps) or is_struct(caps, MapSet) do
    Enum.reduce(caps, MapSet.new(), fn cap, verified ->
      if verify(cap), do: MapSet.put(verified, cap), else: verified
    end)
  end

  def verified_set(_caps), do: MapSet.new()

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

  @doc false
  @spec authorization_context(authorization()) :: {MapSet.t(Capability.t()), map()}
  def authorization_context({:held_by, %URI{} = actor}) do
    {load_held_caps(actor), %{caller: actor}}
  end

  def authorization_context({:admin, %URI{} = admin}) do
    {load_held_caps(admin), %{caller: admin}}
  end

  def authorization_context({:rule, name, %URI{} = configurer}) when is_atom(name) do
    {MapSet.new(), %{caller: configurer, authorization_rule: name}}
  end

  def authorization_context({:genesis, %URI{} = granted_by}) do
    {MapSet.new([Capability.admin_genesis_cap()]), %{caller: granted_by}}
  end

  defp load_held_caps(actor) do
    loader =
      :ezagent_core
      |> Application.fetch_env!(__MODULE__)
      |> Keyword.fetch!(:authority_loader)

    loader.read_held_caps(actor)
  end
end
