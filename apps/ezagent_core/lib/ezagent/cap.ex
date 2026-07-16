defmodule Ezagent.Cap do
  @moduledoc """
  Capability artifact seam.

  The artifact remains an `Ezagent.Capability` struct. `issue/3` stamps
  accountable entity provenance and its receiving grantee, then signs the
  artifact without transferring the issuer's authority. `verify/1` still
  checks provenance at trust boundaries until the Phase 4 verification slice
  replaces that seam with signature verification.

  `issue/3` loads the issuer's held authority through the dependency-inverted
  durable loader and runs the complete grantor-authorization algorithm before
  returning a signed artifact. Downstream handlers only store issued artifacts.
  """

  alias Ezagent.{Capability, CapabilityRegistry}

  @type artifact :: Capability.t()
  @type authorization ::
          {:held_by, URI.t()}
          | {:admin, URI.t()}
          | {:rule, atom(), URI.t()}

  @doc """
  Authorize the issuer, stamp issuer provenance, and produce an artifact.
  """
  @spec issue(authorization(), URI.t(), Capability.t()) ::
          {:ok, artifact()} | {:error, term()}
  def issue(authorization, %URI{} = grantee_uri, %Capability{} = cap) do
    {caps, context} = authorization_context(authorization)

    with :ok <- authorize_issue(authorization, caps, cap, context),
         {:ok, artifact} <- prepare_provenance(authorization, grantee_uri, cap),
         {:ok, artifact} <- Ezagent.Cap.Authority.sign_for_target(artifact) do
      {:ok, artifact}
    end
  end

  @doc """
  Verify a capability artifact's signature, or dual-read a legacy artifact.

  Signed artifacts deny on malformed/untrusted selectors, malformed material,
  invalid provenance, or a bad signature. Once a selector identifies trusted
  key material, infrastructure failures from key derivation or crypto propagate
  to the caller. Unsigned artifacts remain on the temporary legacy #154 path.
  """
  @spec verify(term()) :: boolean()
  def verify(%Capability{grantee_uri: %URI{} = presenter} = artifact),
    do: Ezagent.Cap.Authority.verify_for_target(artifact, presenter)

  def verify(_artifact), do: false

  @doc """
  Verify an artifact for one receiving entity.

  During dual-read, unsigned legacy artifacts are accepted by `verify/1` and
  have no receiver binding. A signed artifact must instead name the exact URI
  struct of the entity whose `:caps` slice will receive it.
  """
  @spec verify_for(term(), URI.t()) :: boolean()
  def verify_for(%Capability{} = cap, %URI{} = receiver_uri) do
    if verify(cap) do
      receiver_matches?(cap, receiver_uri)
    else
      false
    end
  end

  def verify_for(_artifact, _receiver_uri), do: false

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

  @doc """
  Return verified capabilities that may enter `receiver_uri`'s `:caps` slice.

  This is the receiver-aware load/store boundary for signed artifacts. Legacy
  unsigned artifacts remain accepted during the Phase-4 dual-read window.
  """
  @spec verified_set(term(), term()) :: MapSet.t(Capability.t())
  def verified_set(caps, %URI{} = receiver_uri) when is_list(caps) or is_struct(caps, MapSet) do
    Enum.reduce(caps, MapSet.new(), fn cap, verified ->
      if verify_for(cap, receiver_uri), do: MapSet.put(verified, cap), else: verified
    end)
  end

  def verified_set(caps, _receiver_uri) when is_list(caps) or is_struct(caps, MapSet) do
    Enum.reduce(caps, MapSet.new(), fn
      %Capability{signature: nil, key_id: nil, grantee_uri: nil} = cap, verified ->
        if verify(cap), do: MapSet.put(verified, cap), else: verified

      _cap, verified ->
        verified
    end)
  end

  def verified_set(_caps, _receiver_uri), do: MapSet.new()

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

  @doc false
  @spec prepare_provenance(authorization(), URI.t(), Capability.t()) ::
          {:ok, artifact()} | {:error, term()}
  def prepare_provenance(authorization, %URI{} = grantee_uri, %Capability{} = cap) do
    with {:ok, artifact} <- prepare_provenance(authorization, cap) do
      {:ok, %{artifact | grantee_uri: grantee_uri}}
    end
  end

  defp issuer({:held_by, %URI{} = actor}), do: actor
  defp issuer({:admin, %URI{} = admin}), do: admin
  defp issuer({:rule, name, %URI{} = configurer}) when is_atom(name), do: configurer

  defp receiver_matches?(%Capability{signature: nil}, _receiver_uri), do: true
  defp receiver_matches?(%Capability{grantee_uri: receiver_uri}, receiver_uri), do: true
  defp receiver_matches?(_cap, _receiver_uri), do: false

  @doc false
  @spec authorization_context(authorization()) :: {MapSet.t(Capability.t()), map()}
  def authorization_context({:held_by, %URI{} = actor}) do
    {load_held_caps(actor), %{caller: actor}}
  end

  def authorization_context({:admin, %URI{} = admin}) do
    canonical_admin = Ezagent.URI.user(:system, :admin)

    caps =
      if Ezagent.URI.stable_key(admin) == Ezagent.URI.stable_key(canonical_admin) do
        case Ezagent.Cap.Authority.anchor(canonical_admin) do
          {:ok, anchor} -> MapSet.new([anchor])
          {:error, _} -> MapSet.new()
        end
      else
        MapSet.new()
      end

    {caps, %{caller: admin}}
  end

  def authorization_context({:rule, name, %URI{} = configurer}) when is_atom(name) do
    {MapSet.new(), %{caller: configurer, authorization_rule: name}}
  end

  defp load_held_caps(actor) do
    loader =
      :ezagent_core
      |> Application.fetch_env!(__MODULE__)
      |> Keyword.fetch!(:authority_loader)

    loader.read_held_caps(actor)
  end

  defp authorize_issue({:admin, %URI{} = admin}, _caps, _cap, _context) do
    if Ezagent.URI.stable_key(admin) ==
         Ezagent.URI.stable_key(Ezagent.URI.user(:system, :admin)) do
      :ok
    else
      {:error, :canonical_admin_required}
    end
  end

  defp authorize_issue(_authorization, caps, cap, context),
    do: CapabilityRegistry.authorize_grant(caps, cap, context)
end
