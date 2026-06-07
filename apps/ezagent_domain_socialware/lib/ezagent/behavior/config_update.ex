defmodule Ezagent.Behavior.ConfigUpdate do
  @moduledoc """
  Applies approved self-evolve config deltas through the socialware turn gate.

  `apply_delta` accepts only a `turn_id`; the delta itself must already be in
  the settled Turn result. This keeps SW-UPD on the same approval path as
  customer-facing turn output.
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
         attrs <- attrs_from_delta(delta, turn_id, ctx),
         # #607 codex CRITICAL — confused-deputy guard. The dispatch gate only
         # proved the caller may invoke `apply_delta` on THIS session; it did
         # NOT prove the settled delta's `subject_uri` belongs to this session's
         # workspace or is an agent this session manages. The repoint below runs
         # under `system://agent-internal`, so without this check a
         # session-scoped caller could settle a delta naming another tenant's
         # agent and overwrite its cascade layer. Validate the target is within
         # the caller's authority BEFORE writing the object / repointing.
         :ok <- authorize_target(attrs, ctx),
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
    attrs = %{
      layer: Map.fetch!(args, :layer),
      workspace_uri: Map.fetch!(args, :workspace_uri),
      subject_uri: Map.fetch!(args, :subject_uri),
      key: Map.fetch!(args, :key),
      config_id: Map.fetch!(args, :config_id),
      actor_uri: ctx.caller,
      source_turn_id: "repoint:#{URI.to_string(ctx.self_uri)}"
    }

    # #607 codex CRITICAL — same confused-deputy guard as apply_delta. The
    # `workspace_uri`/`subject_uri` here are caller-supplied action args; the
    # repoint runs under `system://agent-internal`, so validate the target is
    # within the caller's authority BEFORE the repoint / pointer write.
    with :ok <- authorize_target(attrs, ctx),
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

  # #607 codex CRITICAL — confused-deputy guard for the agent-internal repoint.
  #
  # The authoritative workspace is derived from `ctx.self_uri` (THIS Socialware
  # session being acted on) — NEVER from the caller-supplied delta/args. Two
  # facts must hold before any object write or repoint:
  #
  #   1. The delta/repoint `workspace_uri` AND the target `subject_uri` both
  #      resolve to that authoritative workspace. A mismatch means the caller is
  #      naming another tenant's workspace/agent → reject loud.
  #   2. The `subject_uri` agent is one this session is authorized to manage —
  #      proven by EITHER session membership (it is in the `:chat` slice's
  #      `members` map) OR spawn-lineage (`AgentLineage.spawned_in_lineage?/2`
  #      walks the spawned-by chain from the agent up to this session). Neither
  #      → reject loud (the session has no authority over an arbitrary agent
  #      that merely happens to sit in the same workspace).
  #
  # Returns `:ok` or `{:error, reason}`; the caller threads it into the `with`
  # BEFORE `ConfigStore.write_config` / the repoint, so an unauthorized target
  # changes nothing.
  @spec authorize_target(map(), map()) :: :ok | {:error, term()}
  defp authorize_target(attrs, ctx) do
    authoritative_ws = session_workspace_name!(ctx.self_uri)
    subject_uri = as_uri(attrs.subject_uri)

    with :ok <- assert_workspace(authoritative_ws, attrs.workspace_uri, :workspace_uri),
         :ok <- assert_workspace(authoritative_ws, subject_uri, :subject_uri),
         :ok <- assert_session_manages(subject_uri, ctx) do
      :ok
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
