defmodule Ezagent.Socialware.CompositionBinding do
  @moduledoc """
  Durable derivation ledger for socialware composition capabilities.

  A row records which installed Definition revision supports one directed
  source-role to target-role capability. Capability identity deliberately omits
  provenance, matching `Ezagent.Capability.revoke/2`; callers must therefore
  reconcile the union of all active rows for a holder instead of reversing one
  row in isolation.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  alias Ezagent.Capability
  alias EzagentCore.Repo

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]

  schema "socialware_composition_bindings" do
    field(:workspace_uri, :string)
    field(:session_uri, :string)
    field(:install_id, :string)
    field(:definition_config_id, :string)
    field(:definition_content_hash, :string)
    field(:source_role, :string)
    field(:target_role, :string)
    field(:source_uri, :string)
    field(:target_uri, :string)
    field(:behavior, :string)
    field(:action, :string)
    field(:issuer_uri, :string)
    field(:cap, :map)
    field(:cap_identity, :string)
    field(:status, Ecto.Enum, values: [:active, :degraded, :inactive], default: :active)
    field(:inactive_reason, :string)
    field(:inactivated_at, :utc_datetime_usec)

    timestamps()
  end

  @type t :: %__MODULE__{}

  @required_fields ~w(
    id workspace_uri session_uri install_id definition_config_id
    definition_content_hash source_role target_role source_uri target_uri
    behavior action issuer_uri cap cap_identity status
  )a

  @doc "Insert or reactivate a binding at its deterministic declaration identity."
  @spec upsert(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t() | term()}
  def upsert(attrs) when is_map(attrs) do
    with {:ok, normalized} <- normalize_attrs(attrs) do
      %__MODULE__{}
      |> changeset(normalized)
      |> Repo.insert(
        on_conflict:
          {:replace,
           [
             :workspace_uri,
             :session_uri,
             :install_id,
             :definition_config_id,
             :definition_content_hash,
             :source_role,
             :target_role,
             :source_uri,
             :target_uri,
             :behavior,
             :action,
             :issuer_uri,
             :cap,
             :cap_identity,
             :status,
             :inactive_reason,
             :inactivated_at,
             :updated_at
           ]},
        conflict_target: [:id],
        returning: true
      )
    end
  end

  @doc "Load one exact binding aggregate row."
  @spec get(String.t()) :: t() | nil
  def get(id) when is_binary(id), do: Repo.get(__MODULE__, id)

  @doc "Deterministic identity for an exact session/install/Definition edge subject."
  @spec id_for(map()) :: String.t()
  def id_for(attrs) when is_map(attrs) do
    {canonical_uri(Map.fetch!(attrs, :session_uri)), Map.fetch!(attrs, :install_id),
     Map.fetch!(attrs, :definition_config_id), Map.fetch!(attrs, :source_role),
     Map.fetch!(attrs, :target_role), canonical_uri(Map.fetch!(attrs, :source_uri)),
     canonical_uri(Map.fetch!(attrs, :target_uri)), Map.fetch!(attrs, :behavior),
     Map.fetch!(attrs, :action)}
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.url_encode64(padding: false)
  end

  @doc false
  @spec mark_degraded(String.t(), atom()) :: {:ok, t()} | {:error, term()}
  def mark_degraded(id, reason) when is_binary(id) and is_atom(reason) do
    now = DateTime.utc_now()

    case Repo.get(__MODULE__, id) do
      %__MODULE__{} = binding ->
        binding
        |> changeset(%{
          status: :degraded,
          inactive_reason: Atom.to_string(reason),
          inactivated_at: now
        })
        |> Repo.update()

      nil ->
        {:error, :composition_binding_not_found}
    end
  end

  @doc "Return active binding rows for a canonical holder URI."
  @spec active_for_holder(URI.t()) :: [t()]
  def active_for_holder(%URI{} = holder_uri) do
    holder = canonical_uri(holder_uri)

    Repo.all(
      from(binding in __MODULE__,
        where: binding.source_uri == ^holder and binding.status == :active,
        order_by: [asc: binding.id]
      )
    )
  end

  @doc "Return active bindings for one session."
  @spec active_for_session(URI.t()) :: [t()]
  def active_for_session(%URI{} = session_uri) do
    session = canonical_uri(session_uri)

    Repo.all(
      from(binding in __MODULE__,
        where: binding.session_uri == ^session and binding.status == :active,
        order_by: [asc: binding.id]
      )
    )
  end

  @doc "Return the durable binding history used to retry union reconciliation."
  @spec for_session(URI.t()) :: [t()]
  def for_session(%URI{} = session_uri) do
    session = canonical_uri(session_uri)

    Repo.all(
      from(binding in __MODULE__,
        where: binding.session_uri == ^session,
        order_by: [asc: binding.id]
      )
    )
  end

  @doc "Return degraded edges for the session read model."
  @spec degraded_for_session(URI.t()) :: [t()]
  def degraded_for_session(%URI{} = session_uri) do
    session = canonical_uri(session_uri)

    Repo.all(
      from(binding in __MODULE__,
        where: binding.session_uri == ^session and binding.status == :degraded,
        order_by: [asc: binding.id]
      )
    )
  end

  @doc "Replace the current session projection atomically, inactivating dropped edges."
  @spec replace_session(URI.t(), [map()]) :: {:ok, [t()]} | {:error, term()}
  def replace_session(%URI{} = session_uri, attrs_list) when is_list(attrs_list) do
    session = canonical_uri(session_uri)

    with {:ok, normalized} <- normalize_many(attrs_list) do
      ids = Enum.map(normalized, &Map.fetch!(&1, :id))
      now = DateTime.utc_now()

      Repo.transaction(fn ->
        from(binding in __MODULE__,
          where:
            binding.session_uri == ^session and binding.status in [:active, :degraded] and
              binding.id not in ^ids
        )
        |> Repo.update_all(
          set: [
            status: :inactive,
            inactive_reason: "definition_edge_dropped",
            inactivated_at: now,
            updated_at: now
          ]
        )

        Enum.map(normalized, &upsert_normalized!/1)
      end)
      |> case do
        {:ok, bindings} -> {:ok, bindings}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc "Does another active binding still support this holder/cap identity?"
  @spec supported?(URI.t(), String.t()) :: boolean()
  def supported?(%URI{} = holder_uri, identity) when is_binary(identity) do
    holder = canonical_uri(holder_uri)

    Repo.exists?(
      from(binding in __MODULE__,
        where:
          binding.source_uri == ^holder and binding.cap_identity == ^identity and
            binding.status == :active
      )
    )
  end

  @doc "Synchronously mark every active binding for a session inactive."
  @spec deactivate_session(URI.t(), atom()) :: {:ok, [URI.t()]} | {:error, term()}
  def deactivate_session(%URI{} = session_uri, reason) when is_atom(reason) do
    deactivate_where(
      dynamic([binding], binding.session_uri == ^canonical_uri(session_uri)),
      reason
    )
  end

  @doc "Synchronously invalidate edges where a departed member is source or target."
  @spec deactivate_member(URI.t(), URI.t(), atom()) :: {:ok, [URI.t()]} | {:error, term()}
  def deactivate_member(%URI{} = session_uri, %URI{} = member_uri, reason)
      when is_atom(reason) do
    session = canonical_uri(session_uri)
    member = canonical_uri(member_uri)

    deactivate_where(
      dynamic(
        [binding],
        binding.session_uri == ^session and
          (binding.source_uri == ^member or binding.target_uri == ^member)
      ),
      reason
    )
  end

  @doc "Stable capability identity, intentionally excluding grant provenance."
  @spec cap_identity(Capability.t()) :: String.t()
  def cap_identity(%Capability{} = cap) do
    {cap.kind, cap.behavior, cap.action, canonical_instance(cap.instance),
     canonical_workspace(cap.workspace_uri)}
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp changeset(binding, attrs) do
    binding
    |> cast(attrs, @required_fields ++ [:inactive_reason, :inactivated_at])
    |> validate_required(@required_fields)
  end

  defp normalize_attrs(%{cap: %Capability{} = cap} = attrs) do
    with {:ok, session_uri} <- required_uri(attrs, :session_uri),
         {:ok, workspace_uri} <- required_uri(attrs, :workspace_uri),
         {:ok, source_uri} <- required_uri(attrs, :source_uri),
         {:ok, target_uri} <- required_uri(attrs, :target_uri),
         {:ok, issuer_uri} <- required_uri(attrs, :issuer_uri),
         behavior when is_atom(behavior) <- Map.get(attrs, :behavior),
         action when is_atom(action) <- Map.get(attrs, :action) do
      identity = cap_identity(cap)

      normalized = %{
        id:
          id_for(%{
            session_uri: session_uri,
            install_id: Map.get(attrs, :install_id),
            definition_config_id: Map.get(attrs, :definition_config_id),
            source_role: Map.get(attrs, :source_role),
            target_role: Map.get(attrs, :target_role),
            source_uri: source_uri,
            target_uri: target_uri,
            behavior: behavior,
            action: action
          }),
        workspace_uri: canonical_uri(workspace_uri),
        session_uri: canonical_uri(session_uri),
        install_id: Map.get(attrs, :install_id),
        definition_config_id: Map.get(attrs, :definition_config_id),
        definition_content_hash: Map.get(attrs, :definition_content_hash),
        source_role: Map.get(attrs, :source_role),
        target_role: Map.get(attrs, :target_role),
        source_uri: canonical_uri(source_uri),
        target_uri: canonical_uri(target_uri),
        behavior: Atom.to_string(behavior),
        action: Atom.to_string(action),
        issuer_uri: canonical_uri(issuer_uri),
        cap: serialize_cap(cap),
        cap_identity: identity,
        status: Map.get(attrs, :status, :active),
        inactive_reason:
          case Map.get(attrs, :degrade_reason) do
            reason when is_atom(reason) -> Atom.to_string(reason)
            reason when is_binary(reason) -> reason
            _ -> nil
          end,
        inactivated_at: nil
      }

      {:ok, normalized}
    else
      _ -> {:error, :invalid_composition_binding}
    end
  end

  defp normalize_attrs(_attrs), do: {:error, :invalid_composition_binding}

  defp normalize_many(attrs_list) do
    Enum.reduce_while(attrs_list, {:ok, []}, fn attrs, {:ok, normalized} ->
      case normalize_attrs(attrs) do
        {:ok, row} -> {:cont, {:ok, [row | normalized]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      error -> error
    end
  end

  defp upsert_normalized!(normalized) do
    %__MODULE__{}
    |> changeset(normalized)
    |> Repo.insert!(
      on_conflict:
        {:replace,
         [
           :workspace_uri,
           :session_uri,
           :install_id,
           :definition_config_id,
           :definition_content_hash,
           :source_role,
           :target_role,
           :source_uri,
           :target_uri,
           :behavior,
           :action,
           :issuer_uri,
           :cap,
           :cap_identity,
           :status,
           :inactive_reason,
           :inactivated_at,
           :updated_at
         ]},
      conflict_target: [:id],
      returning: true
    )
  end

  defp serialize_cap(%Capability{} = cap) do
    %{
      "kind" => Atom.to_string(cap.kind),
      "behavior" => Atom.to_string(cap.behavior),
      "action" => Atom.to_string(cap.action),
      "instance" => serialize_axis(cap.instance),
      "workspace_uri" => serialize_axis(cap.workspace_uri),
      "granted_by" => serialize_axis(cap.granted_by),
      "granted_at" => serialize_granted_at(cap.granted_at)
    }
  end

  defp serialize_axis(%URI{} = uri), do: URI.to_string(uri)
  defp serialize_axis(value) when is_atom(value), do: Atom.to_string(value)
  defp serialize_axis(value), do: inspect(value)

  defp serialize_granted_at(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp serialize_granted_at(value), do: inspect(value)

  defp required_uri(attrs, key) do
    case Map.get(attrs, key) do
      %URI{} = uri -> {:ok, uri}
      _ -> {:error, {:invalid_uri, key}}
    end
  end

  defp deactivate_where(where, reason) do
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      active = dynamic([binding], binding.status == :active)
      current = dynamic([binding], ^where and ^active)
      query = from(binding in __MODULE__, where: ^current)

      holders =
        query
        |> select([binding], binding.source_uri)
        |> distinct(true)
        |> Repo.all()

      query
      |> Repo.update_all(
        set: [
          status: :inactive,
          inactive_reason: Atom.to_string(reason),
          inactivated_at: now,
          updated_at: now
        ]
      )

      Enum.map(holders, &Ezagent.URI.new!/1)
    end)
    |> case do
      {:ok, holders} -> {:ok, holders}
      {:error, reason} -> {:error, reason}
    end
  end

  defp canonical_uri(%URI{} = uri), do: uri |> Ezagent.URI.instance() |> URI.to_string()
  defp canonical_instance(%URI{} = uri), do: canonical_uri(uri)
  defp canonical_instance(other), do: other
  defp canonical_workspace(%URI{} = uri), do: URI.to_string(uri)
  defp canonical_workspace(other), do: other
end
