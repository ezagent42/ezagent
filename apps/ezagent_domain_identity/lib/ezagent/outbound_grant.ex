defmodule Ezagent.OutboundGrant do
  @moduledoc """
  Durable granter-side ledger for capability artifacts issued to an entity.

  This table is an audit and revoke index. It does not store capabilities on
  behalf of the grantee and is not an inbound capability source of truth.
  Consumers record an already-issued artifact; mounting and other delivery
  workflows remain outside this API.

  Rows are tenant-owned by the grantee workspace. `list_by_granter/1` is the
  deliberate system-scope audit read: one issuer may have issued artifacts to
  grantees in several workspaces, so that query spans those grantee-owned
  partitions. `list_by_grantee/1` remains structurally workspace-scoped.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  alias Ezagent.Capability
  alias EzagentCore.Repo

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  @subtypes [:runtime_mount, :composition, :recipe, :ownership, :structural, :genesis]

  schema "outbound_grants" do
    field(:workspace_uri, :string)
    field(:issuer_uri, :string)
    field(:decision_owner_uri, :string)
    field(:grantee_uri, :string)
    field(:cap, :map)
    field(:cap_identity, :string)
    field(:subtype, Ecto.Enum, values: @subtypes)
    field(:session_scope_uri, :string)
    field(:access, :map)
    field(:revoked_at, :utc_datetime_usec)

    timestamps()
  end

  @type subtype ::
          :runtime_mount | :composition | :recipe | :ownership | :structural | :genesis
  @type record_attrs :: %{
          required(:issuer) => URI.t(),
          required(:decision_owner) => URI.t(),
          required(:grantee) => URI.t(),
          required(:cap) => Capability.t(),
          required(:subtype) => subtype(),
          required(:session_scope) => URI.t() | nil,
          required(:access) => map()
        }
  @type t :: %__MODULE__{}

  @required_fields [
    :id,
    :workspace_uri,
    :issuer_uri,
    :decision_owner_uri,
    :grantee_uri,
    :cap,
    :cap_identity,
    :subtype,
    :access
  ]

  @doc """
  Record one already-issued capability artifact idempotently.

  The deterministic identity includes the complete artifact and its audit
  context. A retry returns the existing row, including an existing revocation;
  it never reactivates a revoked artifact. A genuinely new issuance carries a
  new signed payload and therefore receives a new row.
  """
  @spec record(record_attrs()) :: {:ok, t()} | {:error, term()}
  def record(attrs) when is_map(attrs) do
    with {:ok, normalized} <- normalize_attrs(attrs),
         {:ok, _row} <- insert_once(normalized) do
      {:ok, Repo.get!(__MODULE__, normalized.id)}
    end
  end

  @doc """
  Revoke an artifact by row id or by the exact attrs accepted by `record/1`.

  Repeating a revoke preserves the first revocation timestamp. Natural-key
  revocation goes through the same canonicalizer as `record/1`, so it cannot
  accidentally widen into a partial capability match.
  """
  @spec revoke(String.t() | record_attrs()) :: {:ok, t()} | {:error, term()}
  def revoke(id) when is_binary(id), do: revoke_id(id)

  def revoke(attrs) when is_map(attrs) do
    with {:ok, normalized} <- normalize_attrs(attrs) do
      revoke_id(normalized.id)
    end
  end

  @doc """
  List the issuer's complete active and revoked audit history.

  This is intentionally a system-scope read across grantee-owned workspace
  partitions; callers must authorize exposure at their boundary.
  """
  @spec list_by_granter(URI.t()) :: [t()]
  def list_by_granter(%URI{} = issuer) do
    issuer = canonical_entity_string!(issuer, :issuer)

    from(grant in __MODULE__,
      where: grant.issuer_uri == ^issuer,
      order_by: [asc: grant.inserted_at, asc: grant.id]
    )
    |> Repo.all()
  end

  @doc "List the grantee's complete active and revoked workspace-scoped history."
  @spec list_by_grantee(URI.t()) :: [t()]
  def list_by_grantee(%URI{} = grantee) do
    grantee = canonical_entity_string!(grantee, :grantee)
    workspace_uri = Ezagent.Persistence.workspace_uri_for!(grantee)

    __MODULE__
    |> Ezagent.Persistence.scope_by_workspace(workspace_uri)
    |> where([grant], grant.grantee_uri == ^grantee)
    |> order_by([grant], asc: grant.inserted_at, asc: grant.id)
    |> Repo.all()
  end

  defp insert_once(attrs) do
    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert(on_conflict: :nothing, conflict_target: :id)
  end

  defp revoke_id(id) do
    now = DateTime.utc_now()

    from(grant in __MODULE__, where: grant.id == ^id and is_nil(grant.revoked_at))
    |> Repo.update_all(set: [revoked_at: now, updated_at: now])

    case Repo.get(__MODULE__, id) do
      nil -> {:error, :not_found}
      %__MODULE__{} = grant -> {:ok, grant}
    end
  end

  defp changeset(grant, attrs) do
    grant
    |> cast(attrs, @required_fields ++ [:session_scope_uri, :revoked_at])
    |> validate_required(@required_fields)
    |> validate_inclusion(:subtype, @subtypes)
    |> unique_constraint(:id, name: :outbound_grants_pkey)
  end

  defp normalize_attrs(attrs) do
    with {:ok, issuer} <- entity_attr(attrs, :issuer, :invalid_issuer),
         {:ok, decision_owner} <-
           entity_attr(attrs, :decision_owner, :invalid_decision_owner),
         {:ok, grantee} <- entity_attr(attrs, :grantee, :invalid_grantee),
         {:ok, cap} <- cap_attr(attrs),
         {:ok, subtype} <- subtype_attr(attrs),
         {:ok, session_scope} <- session_scope_attr(attrs, grantee.workspace_uri),
         {:ok, access} <- access_attr(attrs),
         :ok <- validate_cap_issuer(cap, issuer.uri),
         :ok <- validate_cap_grantee(cap, grantee.uri),
         :ok <- validate_cap_workspace(cap, grantee.workspace_uri),
         true <- Ezagent.Cap.verify_for(cap, grantee.uri) do
      cap_map = encode_cap(cap)

      normalized = %{
        workspace_uri: grantee.workspace_uri,
        issuer_uri: issuer.string,
        decision_owner_uri: decision_owner.string,
        grantee_uri: grantee.string,
        cap: cap_map,
        cap_identity: cap_identity(cap_map),
        subtype: subtype,
        session_scope_uri: session_scope,
        access: access
      }

      {:ok, Map.put(normalized, :id, natural_id(normalized))}
    else
      false -> {:error, :invalid_cap_artifact}
      {:error, _reason} = error -> error
    end
  end

  defp entity_attr(attrs, key, error) do
    with {:ok, %URI{} = uri} <- Map.fetch(attrs, key),
         {:ok, canonical} <- canonical_entity(uri) do
      {:ok, canonical}
    else
      _ -> {:error, error}
    end
  end

  defp cap_attr(attrs) do
    case Map.fetch(attrs, :cap) do
      {:ok, cap} when is_struct(cap, Capability) -> {:ok, cap}
      _ -> {:error, :invalid_cap}
    end
  end

  defp subtype_attr(attrs) do
    case Map.fetch(attrs, :subtype) do
      {:ok, subtype} when subtype in @subtypes -> {:ok, subtype}
      {:ok, subtype} -> {:error, {:invalid_subtype, subtype}}
      :error -> {:error, {:missing_field, :subtype}}
    end
  end

  defp session_scope_attr(attrs, workspace_uri) do
    case Map.fetch(attrs, :session_scope) do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, %URI{} = uri} ->
        with {:ok, canonical} <- canonical_uri(uri),
             true <- canonical.uri.scheme == "session",
             ^workspace_uri <- Ezagent.Persistence.workspace_uri_for!(canonical.uri) do
          {:ok, canonical.string}
        else
          false -> {:error, :invalid_session_scope}
          {:error, _reason} -> {:error, :invalid_session_scope}
          _other_workspace -> {:error, :session_scope_workspace_mismatch}
        end

      {:ok, _other} ->
        {:error, :invalid_session_scope}

      :error ->
        {:error, {:missing_field, :session_scope}}
    end
  end

  defp access_attr(attrs) do
    case Map.fetch(attrs, :access) do
      {:ok, access} when is_map(access) ->
        if json_map?(access), do: {:ok, access}, else: {:error, :invalid_access}

      {:ok, _other} ->
        {:error, :invalid_access}

      :error ->
        {:error, {:missing_field, :access}}
    end
  end

  defp validate_cap_issuer(cap, issuer) when is_struct(cap, Capability) do
    case cap.granted_by do
      %URI{} = granted_by ->
        if same_uri?(granted_by, issuer), do: :ok, else: {:error, :issuer_mismatch}

      _other ->
        {:error, :issuer_mismatch}
    end
  end

  defp validate_cap_issuer(_cap, _issuer), do: {:error, :issuer_mismatch}

  defp validate_cap_grantee(cap, grantee) when is_struct(cap, Capability) do
    case cap.grantee_uri do
      %URI{} = cap_grantee ->
        if same_uri?(cap_grantee, grantee), do: :ok, else: {:error, :grantee_mismatch}

      _other ->
        {:error, :grantee_mismatch}
    end
  end

  defp validate_cap_grantee(_cap, _grantee), do: {:error, :grantee_mismatch}

  defp validate_cap_workspace(cap, workspace_uri) when is_struct(cap, Capability) do
    case cap.workspace_uri do
      :any ->
        :ok

      %URI{} = cap_workspace ->
        if Ezagent.URI.stable_key(cap_workspace) == workspace_uri,
          do: :ok,
          else: {:error, :cap_workspace_mismatch}

      _other ->
        {:error, :cap_workspace_mismatch}
    end
  end

  defp validate_cap_workspace(_cap, _workspace_uri), do: {:error, :cap_workspace_mismatch}

  defp canonical_entity(%URI{} = uri) do
    with {:ok, canonical} <- canonical_uri(uri),
         true <- canonical.uri.scheme == "entity" do
      {:ok,
       Map.put(
         canonical,
         :workspace_uri,
         Ezagent.Persistence.workspace_uri_for!(canonical.uri)
       )}
    else
      _ -> {:error, :invalid_entity_uri}
    end
  end

  defp canonical_uri(%URI{} = uri) do
    canonical_uri =
      uri |> Ezagent.URI.instance() |> Ezagent.URI.stable_key() |> Ezagent.URI.new!()

    {:ok, %{uri: canonical_uri, string: Ezagent.URI.stable_key(canonical_uri)}}
  rescue
    ArgumentError -> {:error, :invalid_uri}
  end

  defp canonical_entity_string!(uri, role) do
    case canonical_entity(uri) do
      {:ok, canonical} -> canonical.string
      {:error, _reason} -> raise ArgumentError, "#{role} must be a canonical entity URI"
    end
  end

  defp same_uri?(%URI{} = left, %URI{} = right) do
    Ezagent.URI.stable_key(Ezagent.URI.instance(left)) ==
      Ezagent.URI.stable_key(Ezagent.URI.instance(right))
  end

  defp encode_cap(cap) when is_struct(cap, Capability) do
    cap
    |> Jason.encode!()
    |> Jason.decode!()
  end

  defp cap_identity(cap_map) do
    cap_map
    |> Map.take(~w(kind behavior action instance workspace_uri))
    |> deterministic_hash()
  end

  defp natural_id(attrs) do
    attrs
    |> Map.take([
      :workspace_uri,
      :issuer_uri,
      :decision_owner_uri,
      :grantee_uri,
      :cap,
      :subtype,
      :session_scope_uri,
      :access
    ])
    |> deterministic_hash()
  end

  defp deterministic_hash(term) do
    :sha256
    |> :crypto.hash(:erlang.term_to_binary(term, [:deterministic]))
    |> Base.encode16(case: :lower)
  end

  defp json_map?(map) do
    Enum.all?(map, fn {key, value} -> is_binary(key) and json_value?(value) end)
  end

  defp json_value?(value) when is_binary(value) or is_number(value) or is_boolean(value),
    do: true

  defp json_value?(nil), do: true
  defp json_value?(values) when is_list(values), do: Enum.all?(values, &json_value?/1)
  defp json_value?(value) when is_map(value), do: json_map?(value)
  defp json_value?(_value), do: false
end
