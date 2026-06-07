defmodule Ezagent.Behavior.ConfigUpdate do
  @moduledoc """
  Applies approved self-evolve config deltas through the socialware turn gate.

  `apply_delta` accepts only a `turn_id`; the delta itself must already be in
  the settled Turn result. This keeps SW-UPD on the same approval path as
  customer-facing turn output.

  ## No partial cross-store write on caller input (#607 round-5)

  Both `apply_delta` and `repoint` touch TWO durable stores with no shared
  transaction: the target agent's Sandbox (`cascade_resolution.user_layer_uri`)
  and the ConfigStore (immutable object + pointer). The recurring bug class
  (five codex rounds) was a caller-controlled field reaching a store write
  before it was validated, so a later validation failure left ONE store mutated
  and the other not. `validate_and_normalize/2` is the single upfront chokepoint:
  it validates AND normalizes EVERY caller-controlled field (layer, workspace_uri,
  subject_uri, key — plus the confused-deputy authority guard) and `repoint`
  additionally validates `config_id` via `ConfigStore.fetch_matching_object/1`,
  ALL before any side effect. The side effects therefore run only on
  already-validated/normalized values and can fail ONLY on infrastructure (DB
  down / process dead), never on caller input.

  ## Residual non-atomic window (documented, NOT a caller-input bug)

  After the upfront validation, the only remaining non-atomic window is an
  INFRASTRUCTURE failure (DB crash / process death) STRICTLY BETWEEN the sandbox
  repoint and the ConfigStore pointer write. These two writes span two stores
  (a cross-process dispatch to the agent Sandbox, and a `Repo` insert) with no
  shared transaction, and the object-keyed ordering (object → repoint → pointer)
  is deliberately interleaved so the sandbox repoint sits BETWEEN the two
  ConfigStore writes — it cannot be enclosed in a single `Repo.transaction`
  without pulling a cross-process dispatch inside a DB txn (wrong) or reordering
  away the object-keyed atomicity. The ordering already makes every infra-failure
  outcome non-harmful (orphan immutable object, or stale rollback bookkeeping; the
  pointer never resolves stale because each layer URI names a specific immutable
  object). A full 2PC is explicitly out of scope (#607). No caller-supplied value
  can trigger this window — it is reachable only by infrastructure failure.
  """

  # lifecycle:state_slice_override
  use Ezagent.Lifecycle, state_slice: :config_updates

  alias Ezagent.AgentLineage
  alias Ezagent.Socialware.{CascadeRepoint, ConfigStore}

  # `:chat` is read to resolve this session's member set — one of the two
  # signals (membership OR spawn-lineage) that prove the delta's `subject_uri`
  # is an agent THIS session may manage (#607 codex CRITICAL confused-deputy).
  reads_siblings([:turns, :chat])

  action(:apply_delta,
    args: %{turn_id: :string},
    returns: %{config_id: :string, previous_config_id: {:option, :string}},
    caps: [:apply_delta],
    modes: [:call],
    description: "Apply the config delta carried by a settled optimizer turn"
  )

  action(:repoint,
    args: %{
      layer: :atom,
      workspace_uri: :uri,
      subject_uri: :uri,
      key: :string,
      config_id: :string
    },
    returns: %{config_id: :string, previous_config_id: {:option, :string}},
    caps: [:repoint],
    modes: [:call],
    description: "Rollback or advance a config pointer to an existing immutable object"
  )

  @impl Ezagent.Lifecycle
  def create(_args), do: {:ok, %{applied: %{}}}

  @impl Ezagent.Lifecycle
  def activate(_state, _ctx), do: {:ok, %{}}

  @spec data_owner(URI.t() | :any | term()) :: URI.t() | :any | :no_owner
  def data_owner(%URI{scheme: "session"} = session_uri) do
    Ezagent.Behavior.Chat.data_owner(session_uri)
  end

  def data_owner(:any), do: :any
  def data_owner(_), do: :no_owner

  @spec handle_apply_delta(map(), map()) :: {:ok, map(), [term()]} | {:error, term()}
  def handle_apply_delta(%{turn_id: turn_id}, ctx) do
    # #607 codex CRITICAL — OBJECT-KEYED, so apply_delta is ATOMIC-by-ordering
    # across the two durable stores with no shared transaction (spec section 7.4:
    # repoint the agent's high cascade layer "at it" — the new IMMUTABLE config
    # object). The agent's user cascade layer URI names a SPECIFIC immutable
    # object (`ConfigProjection.object_uri/2`), NOT the mutable pointer. The
    # three steps are ordered so no single-step failure leaves harmful
    # uncompensated state:
    #
    #   1. `ConfigStore.write_config` — write the immutable object (fallible,
    #      atomic within itself). On failure NOTHING else has happened.
    #   2. repoint the agent's user cascade layer at the NEW OBJECT's URI. The
    #      object already exists + is immutable, so the layer can never resolve
    #      stale/:none. On failure the object is an orphan (unreferenced row in an
    #      append-only store) and NO pointer moved — non-harmful; a retry writes a
    #      new object and repoints again.
    #   3. `ConfigStore.put_pointer` — current+previous bookkeeping for rollback,
    #      LAST. On failure the agent is already correctly repointed to the new
    #      object (the consume is real); only the rollback-target bookkeeping is
    #      stale — non-harmful (a fresh apply_delta re-establishes it).
    with {:ok, turn} <- settled_turn(ctx, turn_id),
         {:ok, delta} <- config_delta(turn),
         raw_attrs <- attrs_from_delta(delta, turn_id, ctx),
         # #607 round-5 STRUCTURAL — validate AND normalize EVERY caller-controlled
         # input (layer / workspace_uri / subject_uri / key / patch, plus the
         # confused-deputy authority guard) BEFORE any side effect. The five codex
         # rounds were all the same class: a caller-controlled field reaching a
         # store write before it was validated, so a later validation failure (in
         # `put_pointer` / a changeset) left one store mutated and the other not —
         # a partial cross-store write. `validate_and_normalize/2` is the single
         # chokepoint: it returns fully-normalized attrs, so the side effects below
         # run only on already-validated values and can fail ONLY on infrastructure
         # (DB down / process dead), never on caller input.
         {:ok, attrs} <- validate_and_normalize(raw_attrs, ctx),
         body <-
           ConfigStore.merge_delta(
             attrs.layer,
             attrs.workspace_uri,
             attrs.subject_uri,
             attrs.key,
             attrs.patch
           ),
         {:ok, object} <- ConfigStore.write_config(Map.put(attrs, :body, body)),
         {:ok, repoint_status} <- repoint_agent_layer(attrs, object.id),
         {:ok, %{previous_config_id: previous}} <-
           ConfigStore.put_pointer(Map.put(attrs, :config_id, object.id)) do
      applied = ctx.read.(:applied, %{})

      reply = %{
        config_id: object.id,
        previous_config_id: previous,
        repoint_status: repoint_status
      }

      {:ok, reply, [{:set, :applied, Map.put(applied, turn_id, reply)}]}
    end
  end

  # #607 — consume seam: repoint the subject agent's #17 high (user) cascade layer
  # at the IMMUTABLE config object's stable resource URI, so the next spawn
  # re-materializes the new soul. `subject_uri` IS the target agent.
  #
  # `CascadeRepoint.repoint_user_layer/3` writes the object URI into the agent's
  # DURABLE spawn source (its Sandbox `respawn_template_data.cascade_resolution`,
  # snapshot-persisted), so a cold next-spawn resolves it — this is what makes
  # the consume real, not write-only (#607 codex HIGH). The sandbox read/write
  # runs under `system://agent-internal` (the user's caps already gated the
  # action; the sandbox effect is agent-internal). Success -> `:repointed`.
  #
  # Every error FAILS LOUD (no silent `:deferred`):
  #
  #   * `:no_cascade_resolution` — the agent has a sandbox but NO
  #     `cascade_resolution` map (a pre-cascade / non-credentialled agent). It
  #     STRUCTURALLY cannot consume a `user_layer_uri`, and inventing one would
  #     diverge from #17's create-time resolution. There is no durable place to
  #     record the pointer, so returning success would be a silent no-op that
  #     falsely reports the config as applied — surface it as an error instead.
  #   * any other dispatch/write error (`:no_such_actor` for a never-spawned
  #     agent, cap denial, write failure) — likewise loud.
  defp repoint_agent_layer(attrs, object_id) do
    case CascadeRepoint.repoint_user_layer(
           attrs.subject_uri,
           attrs.workspace_uri,
           object_id
         ) do
      :ok -> {:ok, :repointed}
      {:error, _reason} = err -> err
    end
  end

  @spec handle_repoint(map(), map()) :: {:ok, map(), [term()]} | {:error, term()}
  def handle_repoint(args, ctx) do
    # Rollback / explicit advance: repoint the agent's user cascade layer at the
    # TARGET immutable object (`config_id`), then update the pointer bookkeeping.
    # Same object-keyed ordering as apply_delta: the target object already exists
    # + is immutable, so the layer can never resolve stale; the bookkeeping write
    # is LAST so a failure there leaves the agent correctly repointed.
    raw_attrs = %{
      layer: Map.fetch!(args, :layer),
      workspace_uri: Map.fetch!(args, :workspace_uri),
      subject_uri: Map.fetch!(args, :subject_uri),
      key: Map.fetch!(args, :key),
      config_id: Map.fetch!(args, :config_id),
      actor_uri: ctx.caller,
      source_turn_id: "repoint:#{URI.to_string(ctx.self_uri)}"
    }

    # #607 round-5 STRUCTURAL — same single upfront chokepoint as apply_delta.
    # `validate_and_normalize/2` runs the confused-deputy authority guard AND
    # validates+normalizes EVERY caller-controlled field (layer / workspace_uri /
    # subject_uri / key) BEFORE any side effect. Round-5 specifically: `layer`
    # was only validated inside `put_pointer` (`normalize_layer!`), which runs
    # AFTER the sandbox repoint — so `layer: :bogus` with a valid config_id
    # repointed the sandbox, then raised in put_pointer, leaving a partial
    # cross-store write. It is now rejected loud upfront.
    #
    # #607 codex round-4 HIGH — the caller-supplied `config_id` is ALSO untrusted
    # and names an EXISTING immutable object. `fetch_matching_object` (still
    # BEFORE any side effect) rejects a nonexistent id or one whose
    # workspace/subject/key belong to another tenant. Only a validated, in-scope
    # object proceeds to repoint + pointer write (no partial write on rejection).
    with {:ok, attrs} <- validate_and_normalize(raw_attrs, ctx),
         {:ok, _object} <- ConfigStore.fetch_matching_object(attrs),
         {:ok, :repointed} <- repoint_agent_layer(attrs, attrs.config_id),
         {:ok, %{previous_config_id: previous}} <- ConfigStore.put_pointer(attrs) do
      {:ok, %{config_id: attrs.config_id, previous_config_id: previous}, []}
    end
  end

  defp settled_turn(ctx, turn_id) do
    turns =
      ctx
      |> Map.get(:siblings, %{})
      |> Map.get(:turns, %{})
      |> Map.get(:turns, %{})

    case Map.fetch(turns, turn_id) do
      {:ok, %{status: :settled} = turn} -> {:ok, turn}
      {:ok, %{status: status}} -> {:error, {:turn_not_settled, status}}
      :error -> {:error, :unknown_turn}
    end
  end

  defp config_delta(%{result: %{config_delta: delta}}) when is_map(delta), do: {:ok, delta}
  defp config_delta(_turn), do: {:error, :missing_config_delta}

  # #607 round-5 STRUCTURAL — the SINGLE upfront chokepoint. Validate AND
  # normalize EVERY caller-controlled input BEFORE any side effect, in BOTH
  # `handle_apply_delta` and `handle_repoint`. Returns `{:ok, normalized_attrs}`
  # or `{:error, reason}`; the caller threads it into the `with` BEFORE
  # `ConfigStore.write_config` / the agent-internal repoint / `put_pointer`, so an
  # invalid OR unauthorized input changes nothing in either durable store.
  #
  # The five codex rounds were one bug class: a caller-controlled field reaching a
  # store write before validation, so a later validation failure (in `put_pointer`
  # via `normalize_layer!`, or in a changeset) left the agent sandbox mutated but
  # the ConfigStore pointer not — a partial cross-store write with no shared txn.
  # Per-field patching (round 4 = config_id, round 5 = layer) did not converge.
  # This validates the WHOLE caller surface upfront and returns normalized values
  # so the side effects can fail ONLY on infrastructure, never on caller input.
  #
  # Fields validated/normalized (every caller-controlled value `put_pointer`,
  # `write_config`, the changesets, or `CascadeRepoint` could reject):
  #
  #   * `layer`        — `ConfigStore.normalize_layer/1` (SAME `@layers` allow-list
  #                      `normalize_layer!` enforces at the write boundary). An
  #                      invalid layer can NO LONGER reach a write. [round-5]
  #   * `workspace_uri`— `ConfigStore.normalize_uri/2` (URI-shape) THEN the
  #                      confused-deputy `assert_workspace` (must resolve to the
  #                      authoritative workspace derived from `ctx.self_uri`).
  #   * `subject_uri`  — `ConfigStore.normalize_uri/2` THEN `assert_workspace` AND
  #                      `assert_session_manages` (membership OR spawn-lineage).
  #   * `key`          — `ConfigStore.validate_key/1` (non-empty string; the
  #                      object changeset `validate_required` + pointer key/id).
  #
  # The authoritative workspace is derived from `ctx.self_uri` (THIS Socialware
  # session being acted on) — NEVER from the caller-supplied delta/args.
  # `config_id` (repoint only) is validated by `ConfigStore.fetch_matching_object`
  # which the caller runs immediately after this, still before any side effect.
  @spec validate_and_normalize(map(), map()) :: {:ok, map()} | {:error, term()}
  defp validate_and_normalize(attrs, ctx) do
    authoritative_ws = session_workspace_name!(ctx.self_uri)

    with {:ok, layer} <- ConfigStore.normalize_layer(attrs.layer),
         {:ok, workspace_uri} <- ConfigStore.normalize_uri(attrs.workspace_uri, :workspace_uri),
         {:ok, subject_uri} <- ConfigStore.normalize_uri(attrs.subject_uri, :subject_uri),
         {:ok, key} <- ConfigStore.validate_key(attrs.key),
         :ok <- assert_workspace(authoritative_ws, workspace_uri, :workspace_uri),
         :ok <- assert_workspace(authoritative_ws, subject_uri, :subject_uri),
         :ok <- assert_session_manages(as_uri(subject_uri), ctx) do
      {:ok,
       attrs
       |> Map.put(:layer, layer)
       |> Map.put(:workspace_uri, workspace_uri)
       |> Map.put(:subject_uri, subject_uri)
       |> Map.put(:key, key)}
    end
  end

  # The authoritative workspace name comes from THIS session's own URI — the one
  # the dispatch gate proved the caller may act on — not from any caller input.
  defp session_workspace_name!(self_uri) do
    case Ezagent.URI.workspace_of(as_uri(self_uri)) do
      %URI{} = ws ->
        case Ezagent.URI.workspace_name(ws) do
          {:ok, name} ->
            name

          :error ->
            raise ArgumentError,
                  "socialware session has no workspace name: #{URI.to_string(as_uri(self_uri))}"
        end

      :any ->
        raise ArgumentError,
              "socialware session URI is not workspace-bound: " <>
                URI.to_string(as_uri(self_uri))
    end
  end

  # Reject (loud) unless `uri` resolves to `authoritative_ws`. Used for both the
  # delta/repoint `workspace_uri` and the `subject_uri` so a forged value naming
  # another tenant cannot reach the agent-internal repoint.
  defp assert_workspace(authoritative_ws, uri, label) do
    candidate = as_uri(uri)

    case Ezagent.URI.workspace_of(candidate) do
      %URI{} = ws ->
        case Ezagent.URI.workspace_name(ws) do
          {:ok, ^authoritative_ws} ->
            :ok

          {:ok, other} ->
            {:error,
             {:cross_tenant_target,
              %{
                field: label,
                expected_workspace: authoritative_ws,
                got_workspace: other,
                uri: URI.to_string(candidate)
              }}}

          :error ->
            {:error, {:target_without_workspace, %{field: label, uri: URI.to_string(candidate)}}}
        end

      :any ->
        {:error, {:target_without_workspace, %{field: label, uri: URI.to_string(candidate)}}}
    end
  end

  # The subject agent must be one this session may manage: a current session
  # member OR an agent in this session's spawn lineage. An in-workspace agent
  # that is neither is rejected — same-workspace co-residence is not authority.
  defp assert_session_manages(subject_uri, ctx) do
    if session_member?(subject_uri, ctx) or
         AgentLineage.spawned_in_lineage?(subject_uri, as_uri(ctx.self_uri)) do
      :ok
    else
      {:error,
       {:subject_not_managed_by_session,
        %{
          subject_uri: URI.to_string(subject_uri),
          session_uri: URI.to_string(as_uri(ctx.self_uri))
        }}}
    end
  end

  # The `:chat` sibling slice keys `members` by the member's `%URI{}`.
  defp session_member?(subject_uri, ctx) do
    ctx
    |> Map.get(:siblings, %{})
    |> Map.get(:chat, %{})
    |> Map.get(:members, %{})
    |> Map.has_key?(subject_uri)
  end

  defp as_uri(%URI{} = uri), do: uri
  defp as_uri(uri) when is_binary(uri), do: Ezagent.URI.new!(uri)

  defp attrs_from_delta(delta, turn_id, ctx) do
    %{
      layer: Map.get(delta, :layer) || Map.fetch!(delta, "layer"),
      workspace_uri: Map.get(delta, :workspace_uri) || Map.fetch!(delta, "workspace_uri"),
      subject_uri: Map.get(delta, :subject_uri) || Map.fetch!(delta, "subject_uri"),
      key: Map.get(delta, :key) || Map.fetch!(delta, "key"),
      patch: Map.get(delta, :patch) || Map.fetch!(delta, "patch"),
      actor_uri: ctx.caller,
      source_turn_id: turn_id
    }
  end
end
