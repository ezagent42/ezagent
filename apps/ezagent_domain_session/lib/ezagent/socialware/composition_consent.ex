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
    # `binding_id` is set for composition consents; NULL for a binding-less
    # URI-share consent, which names its target/grantee directly instead.
    field(:binding_id, :string)
    field(:target_uri, :string)
    field(:grantee_uri, :string)
    # M3: the specific access this consent is bound to (URI-share rows).
    field(:behavior, :string)
    field(:actions_json, :string)
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
    id workspace_uri binding_id target_uri grantee_uri behavior actions_json
    target_approval source_approval
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

  # --- URI-share entry (A3): the LOOSER case of this same mechanism -----------
  #
  # composition consent = two-party (target ISSUE + source STORE) approval of a
  # BINDING. URI-share consent is the relaxation: NO binding, and the SOURCE side
  # is auto-satisfied (the requester IS the recipient, so its consent to receive
  # is implicit). So it reuses this exact state machine + owner todo-box, keyed by
  # `(target, grantee, behavior, actions)` with `binding_id` NULL. M3 hardens two
  # edges: the requester must equal the authenticated principal (no third-party
  # fabrication), and a decision is authorized against the target's CURRENT
  # data_owner (not the request-time snapshot). The composition `sync`/`command`
  # path above is unchanged (it always sets `binding_id` + both sides).

  @doc """
  Request URI-share owner consent for `requester` to be elevated on `target_uri`
  for `behavior`'s `actions`. The looser case: no `CompositionBinding`, source
  side auto-satisfied (the requester IS the recipient).

  **M3 — authenticated requester + scope-bound consent.** `requester` is checked
  against `authenticated_principal` (the transport's authenticated caller): they
  MUST be the same identity, else `:consent_requester_not_authenticated`. Without
  this, any caller could fabricate a "recipient consents" attestation for a third
  party (the approver would then be approving a *claimed* requester). The consent
  is keyed by `(target, requester, behavior, actions)` — a different behavior or
  action-set is a DIFFERENT consent needing its own approval, so one approval can
  never be reused to cover an access the owner did not see. Creates — idempotently
  by that scoped key — a pending consent whose target owner = the target's current
  `data_owner`. Fails closed (`:consent_target_owner_unresolvable`) if the owner
  cannot resolve.

  **Codex round-3 — `authenticated_principal` is a plain argument, not yet a real
  boundary.** There are ZERO production call sites of this function today — every
  caller is a test that supplies both `requester` and `authenticated_principal`
  itself (pinned by
  `test/invariants/composition_consent_request_no_production_callers_test.exs`,
  which goes RED the moment a non-test call site appears). The `requester ==
  authenticated_principal` check above is necessary but not sufficient: it only
  defends against forgery if `authenticated_principal` itself was fixed by a
  verified transport, which nothing enforces while this function is unreachable
  from production. **Before wiring the FIRST production caller** — the A3 plan's
  deferred Group B (kanban rule-8's hand-rolled approval migrating onto this
  entry) or any future URI-share dispatch action — that caller MUST derive
  `authenticated_principal` from the dispatch/Kind runtime's authenticated
  context (`ctx.caller` / `ctx.authenticated_principal` — the same fields
  `Ezagent.Cmd.authenticated_external/5` fixes at the auth boundary, and that
  `handle_composition_consent/2` already threads `ctx.caller` into `command/6`
  for the composition two-party approval path), never a value read out of
  `args` or otherwise caller-controlled. Reopen security review before merging
  that caller; do not just delete the invariant test to make it pass.
  """
  @spec request(URI.t(), URI.t(), module(), [atom()], URI.t()) ::
          {:ok, t()} | {:error, term()}
  def request(
        %URI{} = target_uri,
        %URI{} = requester,
        behavior,
        actions,
        %URI{} = authenticated_principal
      )
      when is_atom(behavior) and is_list(actions) and actions != [] do
    # M3: the requester is not a free-standing claim — it must equal the
    # authenticated principal the transport verified. A forged third-party
    # requester is rejected before anything is written.
    if same_instance?(requester, authenticated_principal) do
      insert_share_request(target_uri, requester, behavior, actions)
    else
      {:error, :consent_requester_not_authenticated}
    end
  end

  def request(_target, _requester, _behavior, _actions, _principal),
    do: {:error, :invalid_consent_request}

  defp insert_share_request(target_uri, requester, behavior, actions) do
    case Ezagent.CapabilityRegistry.data_owner_of(behavior, Ezagent.URI.instance(target_uri)) do
      %URI{} = owner ->
        id = share_consent_id(target_uri, requester, behavior, actions)

        case Repo.get(__MODULE__, id) do
          %__MODULE__{} = existing ->
            {:ok, existing}

          nil ->
            now = DateTime.utc_now()

            %__MODULE__{}
            |> changeset(%{
              id: id,
              binding_id: nil,
              target_uri: uri_string(target_uri),
              grantee_uri: uri_string(requester),
              behavior: behavior_string(behavior),
              actions_json: encode_actions(actions),
              workspace_uri: uri_string(Ezagent.Capability.workspace_of(target_uri)),
              target_owner_uri: uri_string(owner),
              # Source side auto-satisfied: the AUTHENTICATED requester IS the
              # recipient, so the source attestation is not forgeable.
              source_approval: :approved,
              source_owner_uri: uri_string(requester),
              source_approver_uri: uri_string(requester),
              source_decided_at: now
            })
            |> Repo.insert()
        end

      _ ->
        {:error, :consent_target_owner_unresolvable}
    end
  end

  @doc """
  The target owner decides (`:approve` / `:deny`) a `request/5` (URI-share)
  consent by its `id`. Authenticated against the consent row's stored
  `target_owner_uri` (no `CompositionBinding` / session). Idempotent via
  `idempotency_key`.
  """
  @spec decide(String.t(), :approve | :deny, URI.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def decide(id, decision, %URI{} = actor, idempotency_key)
      when is_binary(id) and decision in [:approve, :deny] and
             is_binary(idempotency_key) and idempotency_key != "" do
    Repo.transaction(fn ->
      case Repo.get(CompositionConsentCommand, idempotency_key) do
        %CompositionConsentCommand{} = replay -> replay_decide(replay, id, decision, actor)
        nil -> apply_decide(id, decision, actor, idempotency_key)
      end
    end)
    |> case do
      {:ok, {:ok, consent}} -> {:ok, consent}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  def decide(_id, _decision, _actor, _key), do: {:error, :invalid_consent_command}

  # M3: the consent identity includes the authorization SCOPE (behavior + its
  # actions), not just `(target, grantee)`. Same pair + a different behavior /
  # action-set = a DIFFERENT consent row needing its own approval, so an owner's
  # approval of access A can never be silently reused as approval of access B.
  defp share_consent_id(%URI{} = target, %URI{} = grantee, behavior, actions) do
    "share:" <>
      Ezagent.URI.stable_key(Ezagent.URI.instance(target)) <>
      ":" <>
      Ezagent.URI.stable_key(Ezagent.URI.instance(grantee)) <>
      ":" <> scope_digest(behavior, actions)
  end

  # A stable, order-independent digest of the granted scope. Actions are sorted
  # so `[:a, :b]` and `[:b, :a]` collapse to one consent; behavior is included so
  # two behaviors' same-named actions never collide.
  #
  # Codex round-3: hashing a comma-JOINED string of action names is ambiguous —
  # `[:"read,write"]` and `[:read, :write]` both sort/join to the literal string
  # `"read,write"`, so they hashed identically (a distinct-scope collision this
  # module's own doc promises can't happen). `:erlang.term_to_binary/1` encodes
  # the `{behavior, actions}` tuple in Erlang's self-describing external term
  # format — every atom is length-prefixed, so no encoding of one term can ever
  # equal the encoding of a structurally different term. That kills the whole
  # collision class, not just this one instance.
  defp scope_digest(behavior, actions) do
    {behavior, Enum.sort(actions)}
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  defp apply_decide(id, decision, actor, idempotency_key) do
    with %__MODULE__{} = consent <-
           Repo.one(from(row in __MODULE__, where: row.id == ^id, lock: "FOR UPDATE")),
         # M3: authorize against the target's CURRENT data_owner, NOT the
         # request-time `target_owner_uri` — a transferred/changed target must be
         # decided by whoever owns it NOW, and a stale ex-owner cannot approve.
         {:ok, current_owner} <- current_target_owner(consent),
         :ok <- owner_match(current_owner, actor, :consent_actor_not_target_owner),
         {:ok, state} <- transition(consent.target_approval, decision) do
      now = DateTime.utc_now()

      updated =
        consent
        |> changeset(%{
          target_approval: state,
          target_approver_uri: uri_string(actor),
          target_decided_at: now
        })
        |> Repo.update!()

      %CompositionConsentCommand{}
      |> CompositionConsentCommand.changeset(%{
        idempotency_key: idempotency_key,
        workspace_uri: consent.workspace_uri,
        consent_id: id,
        side: :target,
        command: decision,
        actor_uri: uri_string(actor),
        result_state: state,
        inserted_at: now
      })
      |> Repo.insert!()

      {:ok, updated}
    else
      nil -> {:error, :consent_request_not_found}
      {:error, _} = error -> error
    end
  end

  defp replay_decide(replay, id, decision, actor) do
    if replay.consent_id == id and replay.side == :target and
         replay.command == decision and replay.actor_uri == uri_string(actor) do
      case Repo.get(__MODULE__, id) do
        %__MODULE__{} = consent -> {:ok, consent}
        _ -> {:error, :consent_request_not_found}
      end
    else
      {:error, :consent_idempotency_conflict}
    end
  end

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
    # `binding_id` is NOT required — a URI-share consent has none (it names its
    # target/grantee directly). Composition rows still always set it.
    |> validate_required([:id, :workspace_uri, :target_approval, :source_approval])
    |> validate_shape()
    |> check_constraint(:binding_id,
      name: :consent_binding_xor_uri_share,
      message: "must be either a composition (binding_id) OR a URI-share (target+grantee) consent"
    )
  end

  # M4: mirror the DB CHECK in the changeset so an ambiguous/malformed row fails
  # loud BEFORE the insert — exactly one shape: composition (binding_id, no direct
  # target/grantee) XOR URI-share (no binding, target+grantee both set).
  defp validate_shape(changeset) do
    binding = get_field(changeset, :binding_id)
    target = get_field(changeset, :target_uri)
    grantee = get_field(changeset, :grantee_uri)

    composition? = not is_nil(binding) and is_nil(target) and is_nil(grantee)
    uri_share? = is_nil(binding) and not is_nil(target) and not is_nil(grantee)

    if composition? or uri_share? do
      changeset
    else
      add_error(
        changeset,
        :binding_id,
        "must be either a composition (binding_id) OR a URI-share (target+grantee) consent"
      )
    end
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

  defp same_instance?(%URI{} = a, %URI{} = b) do
    Ezagent.URI.stable_key(Ezagent.URI.instance(a)) ==
      Ezagent.URI.stable_key(Ezagent.URI.instance(b))
  end

  # M3: re-resolve the target's CURRENT data_owner for a URI-share consent (has a
  # stored behavior + target_uri). Composition rows (no direct behavior/target)
  # fall back to the recorded owner — their owner authority rides the binding.
  defp current_target_owner(%__MODULE__{behavior: b, target_uri: t})
       when is_binary(b) and is_binary(t) do
    case Ezagent.CapabilityRegistry.data_owner_of(
           Module.concat([b]),
           Ezagent.URI.instance(Ezagent.URI.new!(t))
         ) do
      %URI{} = owner -> {:ok, owner}
      _ -> {:error, :consent_target_owner_unresolvable}
    end
  end

  defp current_target_owner(%__MODULE__{target_owner_uri: stored}) when is_binary(stored),
    do: {:ok, Ezagent.URI.new!(stored)}

  defp current_target_owner(%__MODULE__{}), do: {:error, :consent_target_owner_unresolvable}

  # Stored as `inspect(module)` (no `Elixir.` prefix) — `Module.concat/1` decodes.
  defp behavior_string(behavior) when is_atom(behavior), do: inspect(behavior)

  defp encode_actions(actions) when is_list(actions),
    do: Jason.encode!(Enum.map(actions, &Atom.to_string/1))
end
