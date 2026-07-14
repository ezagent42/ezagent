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
  alias Ezagent.Cap.Signing

  @legacy_fallback_event [:ezagent, :cap, :legacy_fallback]

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
  def issue(authorization, %URI{} = grantee_uri, %Capability{} = cap) do
    {caps, context} = authorization_context(authorization)

    with :ok <- CapabilityRegistry.authorize_grant(caps, cap, context),
         {:ok, artifact} <- prepare_provenance(authorization, grantee_uri, cap) do
      {:ok, sign_artifact(artifact)}
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
  def verify(%Capability{
        signature: nil,
        key_id: nil,
        grantee_uri: nil,
        granted_by: %URI{scheme: "entity"} = granted_by
      }) do
    :telemetry.execute(@legacy_fallback_event, %{count: 1}, %{granted_by: granted_by})
    true
  end

  def verify(
        %Capability{
          signature: signature,
          workspace_uri: workspace_uri
        } = cap
      )
      when is_binary(signature) and (is_struct(workspace_uri, URI) or workspace_uri == :any) do
    with {:ok, version} <- Signing.parse_key_id(cap.key_id, workspace_uri),
         %URI{scheme: "entity"} = granted_by <- cap.granted_by,
         true <- valid_signed_shape?(cap) do
      trust_domain = Signing.trust_domain(workspace_uri)
      {public_key, _private_key} = Signing.derive_keypair(granted_by, trust_domain, version)

      Signing.verify(cap, signature, public_key)
    else
      _ -> false
    end
  end

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
  defp issuer({:genesis, %URI{} = granted_by}), do: granted_by

  defp valid_signed_shape?(%Capability{
         kind: kind,
         behavior: behavior,
         action: action,
         instance: instance,
         granted_at: %DateTime{},
         grantee_uri: %URI{}
       })
       when is_atom(kind) and is_atom(behavior) and is_atom(action) do
    valid_signing_instance?(instance)
  end

  defp valid_signed_shape?(_cap), do: false

  defp valid_signing_instance?(:any), do: true
  defp valid_signing_instance?(%URI{}), do: true
  defp valid_signing_instance?({tag, %URI{}}) when is_atom(tag), do: true
  defp valid_signing_instance?(_instance), do: false

  defp receiver_matches?(%Capability{signature: nil}, _receiver_uri), do: true
  defp receiver_matches?(%Capability{grantee_uri: receiver_uri}, receiver_uri), do: true
  defp receiver_matches?(_cap, _receiver_uri), do: false

  defp sign_artifact(%Capability{} = cap) do
    version = Signing.active_key_version()
    trust_domain = Signing.trust_domain(cap.workspace_uri)
    cap = %{cap | key_id: Signing.key_id(version, trust_domain)}
    {_public_key, private_key} = Signing.derive_keypair(cap.granted_by, trust_domain, version)

    %{cap | signature: Signing.sign(cap, private_key)}
  end

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
