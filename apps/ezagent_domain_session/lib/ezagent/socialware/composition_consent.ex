defmodule Ezagent.Socialware.CompositionConsent do
  @moduledoc """
  Durable two-party consent aggregate for one exact composition binding.

  Target approval authorizes ISSUE by the current target owner. Source approval
  independently authorizes STORE onto the current source owner. Approval
  commands never issue or absorb capabilities; re-materialization remains the
  only mint path and consumes these states after rechecking owner currency.
  """

  use Ecto.Schema

  import Ecto.Changeset
  import Ecto.Query

  alias Ezagent.Socialware.{CompositionBinding, CompositionConsentCommand}
  alias EzagentCore.Repo

  @primary_key {:id, :string, autogenerate: false}
  @timestamps_opts [type: :utc_datetime_usec]
  @states [:pending, :approved, :denied, :revoked, :superseded]

  schema "socialware_composition_consents" do
    field(:workspace_uri, :string)
    field(:binding_id, :string)
    field(:target_approval, Ecto.Enum, values: @states, default: :pending)
    field(:source_approval, Ecto.Enum, values: @states, default: :pending)
    field(:target_owner_uri, :string)
    field(:source_owner_uri, :string)
    field(:target_approver_uri, :string)
    field(:source_approver_uri, :string)
    field(:target_decided_at, :utc_datetime_usec)
    field(:source_decided_at, :utc_datetime_usec)

    timestamps()
  end

  @type t :: %__MODULE__{}
  @sides [:target, :source]
  @commands [:approve, :deny, :revoke]

  @fields ~w(
    id workspace_uri binding_id target_approval source_approval
    target_owner_uri source_owner_uri target_approver_uri source_approver_uri
    target_decided_at source_decided_at
  )a

  @doc "Load the consent aggregate for an exact binding identity."
  @spec get_by_binding(String.t()) :: t() | nil
  def get_by_binding(binding_id) when is_binary(binding_id) do
    Repo.get_by(__MODULE__, binding_id: binding_id)
  end

  @doc "List pending requests addressed to the authenticated owner identity."
  @spec pending_for_owner(URI.t()) :: [t()]
  def pending_for_owner(%URI{} = owner_uri) do
    owner = uri_string(owner_uri)

    Repo.all(
      from(consent in __MODULE__,
        where:
          (consent.target_owner_uri == ^owner and consent.target_approval == :pending) or
            (consent.source_owner_uri == ^owner and consent.source_approval == :pending),
        order_by: [asc: consent.inserted_at, asc: consent.id]
      )
    )
  end

  @doc false
  @spec approved?(t() | nil, :target | :source, URI.t() | term()) :: boolean()
  def approved?(%__MODULE__{} = consent, side, %URI{} = current_owner) when side in @sides do
    Map.fetch!(consent, approval_field(side)) == :approved and
      same_uri_string?(Map.get(consent, owner_field(side)), current_owner)
  end

  def approved?(_consent, _side, _owner), do: false

  @doc false
  @spec sync(CompositionBinding.t(), map()) :: {:ok, t()} | {:error, term()}
  def sync(%CompositionBinding{} = binding, attrs) when is_map(attrs) do
    Repo.transaction(fn ->
      existing =
        Repo.one(
          from(consent in __MODULE__,
            where: consent.binding_id == ^binding.id,
            lock: "FOR UPDATE"
          )
        )

      now = DateTime.utc_now()

      values =
        %{target: Map.get(attrs, :target_owner), source: Map.get(attrs, :source_owner)}
        |> Enum.reduce(base_attrs(binding), fn {side, owner}, acc ->
          required? = Map.get(attrs, required_field(side), false)
          {state, approver, decided_at} = sync_state(existing, side, owner, required?, attrs, now)

          acc
          |> Map.put(approval_field(side), state)
          |> Map.put(owner_field(side), uri_string(owner))
          |> Map.put(approver_field(side), approver)
          |> Map.put(decided_field(side), decided_at)
        end)

      changeset(existing || %__MODULE__{}, values)
      |> Repo.insert_or_update!()
    end)
    |> case do
      {:ok, consent} -> {:ok, consent}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Authenticate and record one owner approval decision with durable replay protection."
  @spec command(
          String.t(),
          URI.t(),
          :target | :source,
          :approve | :deny | :revoke,
          URI.t(),
          String.t()
        ) ::
          {:ok, t()} | {:error, term()}
  def command(binding_id, %URI{} = session_uri, side, command, %URI{} = actor, idempotency_key)
      when is_binary(binding_id) and side in @sides and command in @commands and
             is_binary(idempotency_key) and idempotency_key != "" do
    result =
      Repo.transaction(fn ->
        case Repo.get(CompositionConsentCommand, idempotency_key) do
          %CompositionConsentCommand{} = replay ->
            replay_result(replay, binding_id, session_uri, side, command, actor)

          nil ->
            apply_command(binding_id, session_uri, side, command, actor, idempotency_key)
        end
      end)

    case result do
      {:ok, {:ok, consent}} ->
        maybe_reconcile_revocation(consent, command)

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def command(_binding_id, _session_uri, _side, _command, _actor, _key),
    do: {:error, :invalid_consent_command}

  @doc false
  @spec supersede_inactive(URI.t()) :: :ok
  def supersede_inactive(%URI{} = session_uri) do
    session = uri_string(session_uri)
    now = DateTime.utc_now()

    inactive_ids =
      from(binding in CompositionBinding,
        where: binding.session_uri == ^session and binding.status == :inactive,
        select: binding.id
      )

    from(consent in __MODULE__, where: consent.binding_id in subquery(inactive_ids))
    |> Repo.update_all(
      set: [
        target_approval: :superseded,
        source_approval: :superseded,
        target_decided_at: now,
        source_decided_at: now,
        updated_at: now
      ]
    )

    :ok
  end

  defp apply_command(binding_id, session_uri, side, command, actor, idempotency_key) do
    with %CompositionBinding{status: status} = binding when status != :inactive <-
           Repo.get(CompositionBinding, binding_id, lock: "FOR UPDATE"),
         true <- same_uri_string?(binding.session_uri, session_uri),
         %__MODULE__{} = consent <-
           Repo.one(
             from(row in __MODULE__,
               where: row.binding_id == ^binding_id,
               lock: "FOR UPDATE"
             )
           ),
         :ok <- authenticate_owner(binding, side, actor),
         {:ok, state} <- transition(Map.fetch!(consent, approval_field(side)), command) do
      now = DateTime.utc_now()

      updated =
        consent
        |> changeset(%{
          approval_field(side) => state,
          approver_field(side) => uri_string(actor),
          decided_field(side) => now
        })
        |> Repo.update!()

      %CompositionConsentCommand{}
      |> CompositionConsentCommand.changeset(%{
        idempotency_key: idempotency_key,
        workspace_uri: binding.workspace_uri,
        binding_id: binding.id,
        side: side,
        command: command,
        actor_uri: uri_string(actor),
        result_state: state,
        inserted_at: now
      })
      |> Repo.insert!()

      {:ok, updated}
    else
      nil -> {:error, :consent_request_not_found}
      false -> {:error, :consent_request_session_mismatch}
      %CompositionBinding{status: :inactive} -> {:error, :consent_request_superseded}
      {:error, _} = error -> error
    end
  end

  defp authenticate_owner(binding, :target, actor) do
    behavior = String.to_existing_atom(binding.behavior)
    target = Ezagent.URI.new!(binding.target_uri)

    case Ezagent.CapabilityRegistry.data_owner_of(behavior, target) do
      %URI{} = owner -> owner_match(owner, actor, :consent_actor_not_target_owner)
      _ -> {:error, :consent_target_owner_unresolvable}
    end
  end

  defp authenticate_owner(binding, :source, actor) do
    source = Ezagent.URI.new!(binding.source_uri)

    case Ezagent.CapabilityRegistry.data_owner_of(Ezagent.ActionSet.ApiKeys, source) do
      %URI{} = owner -> owner_match(owner, actor, :consent_actor_not_source_owner)
      _ -> {:error, :consent_source_owner_unresolvable}
    end
  end

  defp owner_match(owner, actor, error) do
    if Ezagent.URI.stable_key(Ezagent.URI.instance(owner)) ==
         Ezagent.URI.stable_key(Ezagent.URI.instance(actor)),
       do: :ok,
       else: {:error, error}
  end

  defp transition(:superseded, _command), do: {:error, :consent_request_superseded}
  defp transition(_state, :approve), do: {:ok, :approved}
  defp transition(_state, :deny), do: {:ok, :denied}
  defp transition(_state, :revoke), do: {:ok, :revoked}

  defp replay_result(replay, binding_id, session_uri, side, command, actor) do
    actor_uri = uri_string(actor)

    if replay.binding_id == binding_id and replay.side == side and replay.command == command and
         replay.actor_uri == actor_uri do
      case {CompositionBinding.get(binding_id), get_by_binding(binding_id)} do
        {%CompositionBinding{} = binding, %__MODULE__{} = consent} ->
          if same_uri_string?(binding.session_uri, session_uri),
            do: {:ok, consent},
            else: {:error, :consent_request_session_mismatch}

        _ ->
          {:error, :consent_request_not_found}
      end
    else
      {:error, :consent_idempotency_conflict}
    end
  end

  defp maybe_reconcile_revocation(consent, command) when command in [:deny, :revoke] do
    case Ezagent.Socialware.CompositionCaps.reconcile_consent_revocation(consent.binding_id) do
      :ok -> {:ok, consent}
      {:error, reason} -> {:error, {:consent_reconcile_failed, reason}}
    end
  end

  defp maybe_reconcile_revocation(consent, _command), do: {:ok, consent}

  defp sync_state(nil, _side, owner, false, attrs, now),
    do: {:approved, uri_string(Map.get(attrs, :configurer)), if(owner, do: now)}

  defp sync_state(nil, _side, _owner, true, _attrs, _now), do: {:pending, nil, nil}

  defp sync_state(existing, side, owner, false, attrs, now) do
    {:approved, uri_string(Map.get(attrs, :configurer)),
     Map.get(existing, decided_field(side)) || if(owner, do: now)}
  end

  defp sync_state(existing, side, %URI{} = owner, true, _attrs, _now) do
    if same_uri_string?(Map.get(existing, owner_field(side)), owner) do
      case Map.fetch!(existing, approval_field(side)) do
        :superseded ->
          {:pending, nil, nil}

        state ->
          {state, Map.get(existing, approver_field(side)), Map.get(existing, decided_field(side))}
      end
    else
      {:pending, nil, nil}
    end
  end

  defp sync_state(_existing, _side, _owner, true, _attrs, _now), do: {:pending, nil, nil}

  defp base_attrs(binding) do
    %{id: binding.id, binding_id: binding.id, workspace_uri: binding.workspace_uri}
  end

  defp changeset(consent, attrs) do
    consent
    |> cast(attrs, @fields)
    |> validate_required([:id, :workspace_uri, :binding_id, :target_approval, :source_approval])
  end

  defp approval_field(:target), do: :target_approval
  defp approval_field(:source), do: :source_approval
  defp owner_field(:target), do: :target_owner_uri
  defp owner_field(:source), do: :source_owner_uri
  defp approver_field(:target), do: :target_approver_uri
  defp approver_field(:source), do: :source_approver_uri
  defp decided_field(:target), do: :target_decided_at
  defp decided_field(:source), do: :source_decided_at
  defp required_field(:target), do: :target_required?
  defp required_field(:source), do: :source_required?

  defp uri_string(%URI{} = uri), do: uri |> Ezagent.URI.instance() |> URI.to_string()
  defp uri_string(_), do: nil

  defp same_uri_string?(value, %URI{} = uri) when is_binary(value) do
    Ezagent.URI.stable_key(Ezagent.URI.new!(value)) ==
      Ezagent.URI.stable_key(Ezagent.URI.instance(uri))
  end

  defp same_uri_string?(_value, _uri), do: false
end
